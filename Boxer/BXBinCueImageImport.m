/* 
 Boxer is copyright 2010-2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/GNU General Public License.txt, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXBinCueImageImport.h"
#import "NSWorkspace+BXMountedVolumes.h"
#import "BXDrive.h"
#import <DiskArbitration/DiskArbitration.h>
#import "RegexKitLite.h"
#import "BXFileTransfer.h"


#pragma mark -
#pragma mark Private method declarations

void unmountCallback(DADiskRef disk, DADissenterRef dissenter, void *operation);


@interface BXBinCueImageImport ()

- (void) _unmountFailed;
- (void) _unmountSucceeded;

@end


#pragma mark -
#pragma mark Implementation

//This callback is called by DADiskUnmount once a disk has finished unmounting/failed to unmount.
void unmountCallback(DADiskRef disk, DADissenterRef dissenter, void *operation)
{
	if (dissenter) [(id)operation _unmountFailed];
	else [(id)operation _unmountSucceeded];
}

@implementation BXBinCueImageImport

+ (BOOL) isSuitableForDrive: (BXDrive *)drive
{
	NSString *drivePath = [drive path];
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	
	NSString *volumePath = [workspace volumeForPath: drivePath];
	
	if ([volumePath isEqualToString: drivePath])
	{
		NSString *volumeType = [workspace volumeTypeForPath: drivePath];
		
		//If it's an audio CD, we can import it just fine.
		if ([volumeType isEqualToString: audioCDVolumeType]) return YES;
		
		//If it's a data CD, check if it has a matching audio volume: if so, then a BIN/CUE image is needed.
		//(Otherwise, we'll let BXCDImageImport handle it.)
		else if ([volumeType isEqualToString: dataCDVolumeType] &&
				 [workspace audioVolumeOfDataCD: volumePath] != nil) return YES;
		
		//Pass on all other volume types.
		return NO;
	}
	return NO;
}

+ (NSString *) nameForDrive: (BXDrive *)drive
{
	NSString *importedName = nil;
	
	importedName = [[[drive path] lastPathComponent] stringByDeletingPathExtension];
	
	//If the drive has a letter, then prepend it in our standard format
	if ([drive letter]) importedName = [NSString stringWithFormat: @"%@ %@", [drive letter], importedName];
	
	importedName = [importedName stringByAppendingPathExtension: @"cdmedia"];
	
	return importedName;
}

- (id <BXDriveImport>) init
{
	if ((self = [super init]))
	{
		manager = [[NSFileManager alloc] init];
 	}
	return self;
}

- (void) dealloc
{
	[manager release], manager = nil;
	[super dealloc];
}


#pragma mark -
#pragma mark Task execution

- (void) main
{
	if ([self isCancelled] || ![self drive] || ![self destinationFolder]) return;
	
	NSString *driveName			= [[self class] nameForDrive: [self drive]];
	NSString *sourcePath		= [[self drive] path];
	NSString *destinationPath	= [[self destinationFolder] stringByAppendingPathComponent: driveName];
	
	NSString *tocName	= @"tracks.toc";
	NSString *cueName	= @"tracks.cue";
	NSString *binName	= @"data.bin";
	
	
	//Determine the /dev/diskx device name for the entire disk
	NSString *volumeDeviceName = [[NSWorkspace sharedWorkspace] BSDNameForVolumePath: sourcePath];
	if (!volumeDeviceName)
	{
		NSDictionary *userInfo = [NSDictionary dictionaryWithObject: sourcePath forKey: NSFilePathErrorKey];
		NSError *unknownDeviceError = [NSError errorWithDomain: NSCocoaErrorDomain
														  code: NSFileReadUnknownError
													  userInfo: userInfo];
		[self setError: unknownDeviceError];
		return;
	}
	NSString *baseDeviceName = [volumeDeviceName stringByMatching: @"(/dev/disk\\d+)(s\\d+)?" capture: 1];
	
	//Use the BSD name to acquire a Disk Arbitration object for the disc
	DASessionRef session = DASessionCreate(kCFAllocatorDefault);
	if (!session)
	{
		[self setError: [BXCDImageImportRipFailedError errorWithDrive: [self drive]]];
		return;
	}
	
	DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, [baseDeviceName fileSystemRepresentation]);
	if (!disk)
	{
		[self setError: [BXCDImageImportRipFailedError errorWithDrive: [self drive]]];
		CFRelease(session);
		return;
	}
	
	NSString *devicePath = nil;
	unsigned long long diskSize = 0;
	
	//Get the I/O Registry device path to feed to cdrdao, and the total size of the volume
	CFDictionaryRef description = DADiskCopyDescription(disk);
	if (description)
	{
		CFStringRef pathRef = CFDictionaryGetValue(description, kDADiskDescriptionDevicePathKey);
		CFNumberRef sizeRef = CFDictionaryGetValue(description, kDADiskDescriptionMediaSizeKey);
		
		devicePath	= [[(NSString *)pathRef copy] autorelease];
		diskSize	= [(NSNumber *)sizeRef unsignedLongLongValue];
		
		CFRelease(description);
	}
	else
	{
		[self setError: [BXCDImageImportRipFailedError errorWithDrive: [self drive]]];
		CFRelease(disk);
		CFRelease(session);
		return;
	}
	
	[self setNumBytes: diskSize];
	
	//Create the destination path since it doesn't (or shouldn't) already exist
	NSError *destinationCreationError = nil;
	BOOL createdDestination = [manager createDirectoryAtPath: destinationPath
								 withIntermediateDirectories: YES
												  attributes: nil
													   error: &destinationCreationError];
	if (!createdDestination)
	{
		[self setError: destinationCreationError];
		CFRelease(disk);
		CFRelease(session);
		return;
	}
	
	[self setImportedDrivePath: destinationPath];
	

	
	//Unmount the disc's volume (without ejecting) so that cdrdao can access the device exclusively
	//DADiskUnmount is asynchronous, so we poll while we wait for it to finish ejecting or not.
	_unmountSucceeded = NO;
	_waitingForUnmount = YES;
	NSRunLoop *loop = [NSRunLoop currentRunLoop];
	DASessionScheduleWithRunLoop(session, [loop getCFRunLoop], kCFRunLoopDefaultMode);
	DADiskUnmount(disk, kDADiskUnmountOptionWhole, unmountCallback, self);
	while (_waitingForUnmount && ![self isCancelled])
	{
		[loop runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.1]];
	}
	DASessionUnscheduleFromRunLoop(session, [loop getCFRunLoop], kCFRunLoopDefaultMode);

	if (_unmountSucceeded)
	{
		//Prepare the cdrdao task
		NSTask *cdrdao = [[NSTask alloc] init];
		NSString *cdrdaoPath = [[NSBundle mainBundle] pathForResource: @"cdrdao" ofType: nil];
		
		//cdrdao uses relative paths in cuesheets as long as we use relative paths, which simplifies our job,
		//so we provide the output file names as arguments and change the working directory to where we want them.
		NSArray *arguments = [NSArray arrayWithObjects:
							  @"read-cd",
							  @"--device", devicePath,
							  @"--driver", @"generic-mmc:0x20000",
							  @"--datafile", binName,
							  tocName,
							  nil];
		
		[cdrdao setCurrentDirectoryPath: destinationPath];
		[cdrdao setLaunchPath:		cdrdaoPath];
		[cdrdao setArguments:		arguments];
		[cdrdao setStandardOutput: [NSFileHandle fileHandleWithNullDevice]];
		
		[self setTask: cdrdao];
		[cdrdao release];
		
		//Run the task to completion and monitor its progress
		[self runTask];
		
		//If the image creation went smoothly, do final cleanup
		if (![self error])
		{
			NSString *tocPath = [destinationPath stringByAppendingPathComponent: tocName];
			if ([manager fileExistsAtPath: tocPath])
			{
				//Now, convert the TOC file to a CUE
				NSTask *toc2cue = [[NSTask alloc] init];
				NSString *toc2cuePath = [[NSBundle mainBundle] pathForResource: @"toc2cue" ofType: nil];
				
				[toc2cue setCurrentDirectoryPath: destinationPath];
				[toc2cue setLaunchPath:	toc2cuePath];
				[toc2cue setArguments:	[NSArray arrayWithObjects:
										 tocName,
										 cueName,
										 nil]];
				
				[toc2cue setStandardOutput: [NSFileHandle fileHandleWithNullDevice]];
				
				//toc2cue takes no time to run, so just wait for it to finish
				[toc2cue launch];
				[toc2cue waitUntilExit];
				[toc2cue release];
				
				//Once the CUE file is ready, delete the original TOC
				if ([manager fileExistsAtPath: [destinationPath stringByAppendingPathComponent: cueName]])
				{
					[manager removeItemAtPath: tocPath error: nil];
				}
				//Treat it as an error if the CUE file was not generated successfully
				else
				{
					[self setError: [BXCDImageImportRipFailedError errorWithDrive: [self drive]]];
				}
			}
			else
			{
				[self setError: [BXCDImageImportRipFailedError errorWithDrive: [self drive]]];
			}
		}

		[self setSucceeded: [self error] == nil];
		
		//Ensure the disk is remounted after we're done with everything, whether we succeeded or failed
		DADiskMount(disk, NULL, kDADiskMountOptionWhole, NULL, NULL);
	}
	else
	{
		//If the drive could not be unmounted, then assume it's still in use
		NSError *discInUse = [BXCDImageImportDiscInUseError errorWithDrive: [self drive]];
		[self setError: discInUse];
	}
	
	//Release Disk Arbitration resources
	CFRelease(disk);
	CFRelease(session);
}

- (void) checkTaskProgress: (NSTimer *)timer
{
	if ([self numBytes] > 0)
	{
		//Rather than bothering to parse the output of cdrdao, we just compare how large
		//the image is so far to the total size of the original disk.
		
		NSString *imagePath = [[self importedDrivePath] stringByAppendingPathComponent: @"data.bin"]; 
		unsigned long long imageSize = [[manager attributesOfItemAtPath: imagePath error: nil] fileSize];
		
		if (imageSize > 0)
		{
			//The image may end up being larger than the original volume, so cap the reported size.
			imageSize = MAX(imageSize, [self numBytes]);
			
			[self setIndeterminate: NO];
			[self setBytesTransferred: imageSize];
			
			BXOperationProgress progress = (float)[self bytesTransferred] / (float)[self numBytes];
			//Add a margin at either side of the progress to account for lead-in, cleanup and TOC conversion
			//TODO: move this upstream into setCurrentProgress or somewhere
			progress = 0.03f + (progress * 0.96f);
			[self setCurrentProgress: progress];
			
			NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
				[NSNumber numberWithUnsignedLongLong:	[self bytesTransferred]],	BXFileTransferBytesTransferredKey,
				[NSNumber numberWithUnsignedLongLong:	[self numBytes]],			BXFileTransferBytesTotalKey,
			nil];
			[self _sendInProgressNotificationWithInfo: info];
		}
	}
}

- (void) _unmountFailed
{
	_unmountSucceeded = NO;
	_waitingForUnmount = NO;
}

- (void) _unmountSucceeded
{
	_unmountSucceeded = YES;
	_waitingForUnmount = NO;
}
@end