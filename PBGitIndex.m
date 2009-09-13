//
//  PBGitIndex.m
//  GitX
//
//  Created by Pieter de Bie on 9/12/09.
//  Copyright 2009 Pieter de Bie. All rights reserved.
//

#import "PBGitIndex.h"
#import "PBGitRepository.h"
#import "PBGitBinary.h"
#import "PBEasyPipe.h"
#import "NSString_RegEx.h"
#import "PBChangedFile.h"

@interface PBGitIndex (IndexRefreshMethods)

- (NSArray *)linesFromNotification:(NSNotification *)notification;
- (NSMutableDictionary *)dictionaryForLines:(NSArray *)lines;
- (void)addFilesFromDictionary:(NSMutableDictionary *)dictionary staged:(BOOL)staged tracked:(BOOL)tracked;

- (void)indexStepComplete;

- (void)indexRefreshFinished:(NSNotification *)notification;
- (void)readOtherFiles:(NSNotification *)notification;
- (void)readUnstagedFiles:(NSNotification *)notification;
- (void)readStagedFiles:(NSNotification *)notification;

@end

@interface PBGitIndex ()

// Returns the tree to compare the index to, based
// on whether amend is set or not.
- (NSString *) parentTree;

@end

@implementation PBGitIndex

@synthesize amend;

- (id)initWithRepository:(PBGitRepository *)theRepository workingDirectory:(NSURL *)theWorkingDirectory
{
	if (!(self = [super init]))
		return nil;

	NSAssert(theWorkingDirectory, @"PBGitIndex requires a working directory");
	NSAssert(theRepository, @"PBGitIndex requires a repository");

	repository = theRepository;
	workingDirectory = theWorkingDirectory;
	files = [NSMutableArray array];

	return self;
}

- (NSArray *)indexChanges
{
	return files;
}

- (void)setAmend:(BOOL)newAmend
{
	if (newAmend == amend)
		return;
	
	amend = newAmend;
	amendEnvironment = nil;

	[self refresh];

	if (!newAmend)
		return;

	// If we amend, we want to keep the author information for the previous commit
	// We do this by reading in the previous commit, and storing the information
	// in a dictionary. This dictionary will then later be read by [self commit:]
	NSString *message = [repository outputForCommand:@"cat-file commit HEAD"];
	NSArray *match = [message substringsMatchingRegularExpression:@"\nauthor ([^\n]*) <([^\n>]*)> ([0-9]+[^\n]*)\n" count:3 options:0 ranges:nil error:nil];
	if (match)
		amendEnvironment = [NSDictionary dictionaryWithObjectsAndKeys:[match objectAtIndex:1], @"GIT_AUTHOR_NAME",
							[match objectAtIndex:2], @"GIT_AUTHOR_EMAIL",
							[match objectAtIndex:3], @"GIT_AUTHOR_DATE",
							nil];
}

- (void)refresh
{
	// If we were already refreshing the index, we don't want
	// double notifications. As we can't stop the tasks anymore,
	// just cancel the notifications
	refreshStatus = 0;
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter]; 
	[nc removeObserver:self]; 

	// Ask Git to refresh the index
	NSFileHandle *updateHandle = [PBEasyPipe handleForCommand:[PBGitBinary path] 
													 withArgs:[NSArray arrayWithObjects:@"update-index", @"-q", @"--unmerged", @"--ignore-missing", @"--refresh", nil]
														inDir:[workingDirectory path]];

	[nc addObserver:self
		   selector:@selector(indexRefreshFinished:)
			   name:NSFileHandleReadToEndOfFileCompletionNotification
			 object:updateHandle];
	[updateHandle readToEndOfFileInBackgroundAndNotify];

}

- (NSString *) parentTree
{
	NSString *parent = amend ? @"HEAD^" : @"HEAD";
	
	if (![repository parseReference:parent])
		// We don't have a head ref. Return the empty tree.
		return @"4b825dc642cb6eb9a060e54bf8d69288fbee4904";

	return parent;
}

- (void)commitWithMessage:(NSString *)commitMessage
{
	NSMutableString *commitSubject = [@"commit: " mutableCopy];
	NSRange newLine = [commitMessage rangeOfString:@"\n"];
	if (newLine.location == NSNotFound)
		[commitSubject appendString:commitMessage];
	else
		[commitSubject appendString:[commitMessage substringToIndex:newLine.location]];
	
	NSString *commitMessageFile;
	commitMessageFile = [repository.fileURL.path stringByAppendingPathComponent:@"COMMIT_EDITMSG"];
	
	[commitMessage writeToFile:commitMessageFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
	
	// TODO: Notification: @"Creating tree..";
	NSString *tree = [repository outputForCommand:@"write-tree"];
	if ([tree length] != 40)
		return; //TODO: commitFailedBecause:@"Could not create a tree";
	
	
	NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"commit-tree", tree, nil];
	NSString *parent = amend ? @"HEAD^" : @"HEAD";
	if ([repository parseReference:parent]) {
		[arguments addObject:@"-p"];
		[arguments addObject:parent];
	}

	int ret = 1;
	NSString *commit = [repository outputForArguments:arguments
										  inputString:commitMessage
							   byExtendingEnvironment:amendEnvironment
											 retValue: &ret];
	
	if (ret || [commit length] != 40)
		return; // TODO: [self commitFailedBecause:@"Could not create a commit object"];
	
	if (![repository executeHook:@"pre-commit" output:nil])
		return; // TODO: [self commitFailedBecause:@"Pre-commit hook failed"];
	
	if (![repository executeHook:@"commit-msg" withArgs:[NSArray arrayWithObject:commitMessageFile] output:nil])
		return; // TODO: [self commitFailedBecause:@"Commit-msg hook failed"];
	
	[repository outputForArguments:[NSArray arrayWithObjects:@"update-ref", @"-m", commitSubject, @"HEAD", commit, nil]
						  retValue: &ret];
	if (ret)
		return; // TODO: [self commitFailedBecause:@"Could not update HEAD"];
	
	if (![repository executeHook:@"post-commit" output:nil])
		return; // [webController setStateMessage:[NSString stringWithFormat:@"Post-commit hook failed, however, successfully created commit %@", commit]];
	else
		//[webController setStateMessage:[NSString stringWithFormat:@"Successfully created commit %@", commit]];
		;
	
	repository.hasChanged = YES;

	amendEnvironment = nil;
	if (amend)
		self.amend = NO;
	else
		[self refresh];
	
}

- (BOOL)stageFiles:(NSArray *)stageFiles
{
	// Input string for update-index
	// This will be a list of filenames that
	// should be updated. It's similar to
	// "git add -- <files>
	NSMutableString *input = [NSMutableString string];

	for (PBChangedFile *file in stageFiles) {
		[input appendFormat:@"%@\0", file.path];
	}
	
	int ret = 1;
	[repository outputForArguments:[NSArray arrayWithObjects:@"update-index", @"--add", @"--remove", @"-z", @"--stdin", nil]
					   inputString:input
						  retValue:&ret];

	if (ret) {
		// FIXME: failed notification?
		NSLog(@"Error when updating index. Retvalue: %i", ret);
		return NO;
	}

	// TODO: Stop Tracking
	for (PBChangedFile *file in stageFiles)
	{
		file.hasUnstagedChanges = NO;
		file.hasStagedChanges = YES;
	}
	// TODO: Resume tracking
	return YES;
}

// TODO: Refactor with above. What's a better name for this?
- (BOOL)unstageFiles:(NSArray *)unstageFiles
{
	NSMutableString *input = [NSMutableString string];

	for (PBChangedFile *file in unstageFiles) {
		[input appendString:[file indexInfo]];
	}

	int ret = 1;
	[repository outputForArguments:[NSArray arrayWithObjects:@"update-index", @"-z", @"--index-info", nil]
					   inputString:input 
						  retValue:&ret];

	if (ret)
	{
		// FIXME: Failed notification
		NSLog(@"Error when updating index. Retvalue: %i", ret);
		return NO;
	}

	// TODO: stop tracking
	for (PBChangedFile *file in unstageFiles)
	{
		file.hasUnstagedChanges = YES;
		file.hasStagedChanges = NO;
	}
	// TODO: resume tracking

	return YES;
}

- (NSString *)diffForFile:(PBChangedFile *)file staged:(BOOL)staged contextLines:(NSUInteger)context
{
	NSString *parameter = [NSString stringWithFormat:@"-U%u", context];
	if (staged) {
		NSString *indexPath = [@":0:" stringByAppendingString:file.path];

		if (file.status == NEW)
			return [repository outputForArguments:[NSArray arrayWithObjects:@"show", indexPath, nil]];

		return [repository outputInWorkdirForArguments:[NSArray arrayWithObjects:@"diff-index", parameter, @"--cached", [self parentTree], @"--", file.path, nil]];
	}

	// unstaged
	if (file.status == NEW) {
		NSStringEncoding encoding;
		NSError *error = nil;
		NSString *path = [[repository workingDirectory] stringByAppendingPathComponent:file.path];
		NSString *contents = [NSString stringWithContentsOfFile:path
												   usedEncoding:&encoding
														  error:&error];
		if (error)
			return nil;

		return contents;
	}

	return [repository outputInWorkdirForArguments:[NSArray arrayWithObjects:@"diff-files", parameter, @"--", file.path, nil]];
}


# pragma mark WebKit Accessibility

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)aSelector
{
	return NO;
}

@end

@implementation PBGitIndex (IndexRefreshMethods)

- (void)indexRefreshFinished:(NSNotification *)notification
{
	if ([(NSNumber *)[(NSDictionary *)[notification userInfo] objectForKey:@"NSFileHandleError"] intValue])
	{
		// TODO: send updatefailed notification?
		return;
	}

	// Now that the index is refreshed, we need to read the information from the index
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter]; 

	// Other files (not tracked, not ignored)
	NSFileHandle *handle = [PBEasyPipe handleForCommand:[PBGitBinary path] 
											   withArgs:[NSArray arrayWithObjects:@"ls-files", @"--others", @"--exclude-standard", @"-z", nil]
												  inDir:[workingDirectory path]];
	[nc addObserver:self selector:@selector(readOtherFiles:) name:NSFileHandleReadToEndOfFileCompletionNotification object:handle]; 
	[handle readToEndOfFileInBackgroundAndNotify];
	refreshStatus++;

	// Unstaged files
	handle = [PBEasyPipe handleForCommand:[PBGitBinary path] 
											   withArgs:[NSArray arrayWithObjects:@"diff-files", @"-z", nil]
												  inDir:[workingDirectory path]];
	[nc addObserver:self selector:@selector(readUnstagedFiles:) name:NSFileHandleReadToEndOfFileCompletionNotification object:handle]; 
	[handle readToEndOfFileInBackgroundAndNotify];
	refreshStatus++;

	// Staged files
	handle = [PBEasyPipe handleForCommand:[PBGitBinary path] 
								 withArgs:[NSArray arrayWithObjects:@"diff-index", @"--cached", @"-z", [self parentTree], nil]
									inDir:[workingDirectory path]];
	[nc addObserver:self selector:@selector(readStagedFiles:) name:NSFileHandleReadToEndOfFileCompletionNotification object:handle]; 
	[handle readToEndOfFileInBackgroundAndNotify];
	refreshStatus++;
}

- (void)readOtherFiles:(NSNotification *)notification
{
	NSArray *lines = [self linesFromNotification:notification];
	NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] initWithCapacity:[lines count]];
	// Other files are untracked, so we don't have any real index information. Instead, we can just fake it.
	// The line below is used to add the file to the index
	// FIXME: request the real file mode
	NSArray *fileStatus = [NSArray arrayWithObjects:@":000000", @"100644", @"0000000000000000000000000000000000000000", @"0000000000000000000000000000000000000000", @"A", nil];
	for (NSString *path in lines) {
		if ([path length] == 0)
			continue;
		[dictionary setObject:fileStatus forKey:path];
	}

	[self addFilesFromDictionary:dictionary staged:NO tracked:NO];
	[self indexStepComplete];	
}

- (void) readStagedFiles:(NSNotification *)notification
{
	NSArray *lines = [self linesFromNotification:notification];
	NSMutableDictionary *dic = [self dictionaryForLines:lines];
	[self addFilesFromDictionary:dic staged:YES tracked:YES];
	[self indexStepComplete];
}

- (void) readUnstagedFiles:(NSNotification *)notification
{
	NSArray *lines = [self linesFromNotification:notification];
	NSMutableDictionary *dic = [self dictionaryForLines:lines];
	[self addFilesFromDictionary:dic staged:NO tracked:YES];
	[self indexStepComplete];
}

- (void) addFilesFromDictionary:(NSMutableDictionary *)dictionary staged:(BOOL)staged tracked:(BOOL)tracked
{
	// TODO: Stop tracking files
	// Iterate over all existing files
	for (PBChangedFile *file in files) {
		NSArray *fileStatus = [dictionary objectForKey:file.path];
		// Object found, this is still a cached / uncached thing
		if (fileStatus) {
			if (tracked) {
				NSString *mode = [[fileStatus objectAtIndex:0] substringFromIndex:1];
				NSString *sha = [fileStatus objectAtIndex:2];
				file.commitBlobSHA = sha;
				file.commitBlobMode = mode;
				
				if (staged)
					file.hasStagedChanges = YES;
				else
					file.hasUnstagedChanges = YES;
			} else {
				// Untracked file, set status to NEW, only unstaged changes
				file.hasStagedChanges = NO;
				file.hasUnstagedChanges = YES;
				file.status = NEW;
			}

			// We handled this file, remove it from the dictionary
			[dictionary removeObjectForKey:file.path];
		} else {
			// Object not found in the dictionary, so let's reset its appropriate
			// change (stage or untracked) if necessary.

			// Staged dictionary, so file does not have staged changes
			if (staged)
				file.hasStagedChanges = NO;
			// Tracked file does not have unstaged changes, file is not new,
			// so we can set it to No. (If it would be new, it would not
			// be in this dictionary, but in the "other dictionary").
			else if (tracked && file.status != NEW)
				file.hasUnstagedChanges = NO;
			// Unstaged, untracked dictionary ("Other" files), and file
			// is indicated as new (which would be untracked), so let's
			// remove it
			else if (!tracked && file.status == NEW)
				file.hasUnstagedChanges = NO;
		}
	}
	// TODO: Finish tracking files

	// Do new files only if necessary
	if (![[dictionary allKeys] count])
		return;

	// All entries left in the dictionary haven't been accounted for
	// above, so we need to add them to the "files" array
	[self willChangeValueForKey:@"indexChanges"];
	for (NSString *path in [dictionary allKeys]) {
		NSArray *fileStatus = [dictionary objectForKey:path];

		PBChangedFile *file = [[PBChangedFile alloc] initWithPath:path];
		if ([[fileStatus objectAtIndex:4] isEqualToString:@"D"])
			file.status = DELETED;
		else if([[fileStatus objectAtIndex:0] isEqualToString:@":000000"])
			file.status = NEW;
		else
			file.status = MODIFIED;

		if (tracked) {
			file.commitBlobMode = [[fileStatus objectAtIndex:0] substringFromIndex:1];
			file.commitBlobSHA = [fileStatus objectAtIndex:2];
		}

		file.hasStagedChanges = staged;
		file.hasUnstagedChanges = !staged;

		[files addObject:file];
	}
	[self didChangeValueForKey:@"indexChanges"];
}

# pragma mark Utility methods
- (NSArray *)linesFromNotification:(NSNotification *)notification
{
	NSData *data = [[notification userInfo] valueForKey:NSFileHandleNotificationDataItem];
	if (!data)
		return [NSArray array];

	NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	// FIXME: Return an error?
	if (!string)
		return [NSArray array];

	// Strip trailing null
	if ([string hasSuffix:@"\0"])
		string = [string substringToIndex:[string length]-1];

	if ([string length] == 0)
		return [NSArray array];

	return [string componentsSeparatedByString:@"\0"];
}

- (NSMutableDictionary *)dictionaryForLines:(NSArray *)lines
{
	NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:[lines count]/2];
	
	// Fill the dictionary with the new information. These lines are in the form of:
	// :00000 :0644 OTHER INDEX INFORMATION
	// Filename

	NSAssert1([lines count] % 2 == 0, @"Lines must have an even number of lines: %@", lines);

	NSEnumerator *enumerator = [lines objectEnumerator];
	NSString *fileStatus;
	while (fileStatus = [enumerator nextObject]) {
		NSString *fileName = [enumerator nextObject];
		[dictionary setObject:[fileStatus componentsSeparatedByString:@" "] forKey:fileName];
	}

	return dictionary;
}

// This method is called for each of the three processes from above.
// If all three are finished (self.busy == 0), then we can delete
// all files previously marked as deletable
- (void)indexStepComplete
{
	// if we're still busy, do nothing :)
	if (--refreshStatus)
		return;

	// At this point, all index operations have finished.
	// We need to find all files that don't have either
	// staged or unstaged files, and delete them

	NSMutableArray *deleteFiles = [NSMutableArray array];
	for (PBChangedFile *file in files) {
		if (!file.hasStagedChanges && !file.hasUnstagedChanges)
			[deleteFiles addObject:file];
	}
	
	if ([deleteFiles count]) {
		[self willChangeValueForKey:@"indexChanges"];
		for (PBChangedFile *file in deleteFiles)
			[files removeObject:file];
		[self didChangeValueForKey:@"indexChanges"];
	}

	// TODO: Sent index refresh finished operation
}

@end
