/* 
 Boxer is copyright 2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import <AppKit/AppKit.h>

//BXHUDLevelIndicatorCell is a shadowed white level indicator
//designed for bezel notifications.
@interface BXHUDLevelIndicatorCell : NSLevelIndicatorCell
{
	NSColor *indicatorColor;
	NSShadow *indicatorShadow;
}

@property (copy, nonatomic) NSColor *indicatorColor;
@property (copy, nonatomic) NSShadow *indicatorShadow;

//Returns the height used for the level indicator at the specified control size
+ (CGFloat) heightForControlSize: (NSControlSize)size;

@end

