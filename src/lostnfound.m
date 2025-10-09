/* HiddenGem - Working Dock menu injection */

#import <AppKit/AppKit.h>
#import "ZKSwizzle.h"

@interface NSApplication (DockPrivate)
- (CFArrayRef)_createDockMenu:(BOOL)enabled;
- (CFArrayRef)_flattenMenu:(NSMenu *)menu flatList:(id)list;
- (CFArrayRef)_flattenMenu:(NSMenu *)menu flatList:(id)list extraUpdateFlags:(NSUInteger)flags;
@end

// Global menu items
static NSMenu *hiddenGemMenu = nil;
static NSMenuItem *hiddenGemItem = nil;
static NSMenu *hiddenGemSubmenu = nil;
static NSMenuItem *testItem = nil;
static BOOL onSonomaOrHigher = NO;

@interface MinimalHiddenGem : NSObject
+ (instancetype)sharedInstance;
- (void)testAction:(id)sender;
@end

@implementation MinimalHiddenGem

static MinimalHiddenGem *sharedInstance = nil;

+ (instancetype)sharedInstance {
    if (!sharedInstance) {
        sharedInstance = [[self alloc] init];
    }
    return sharedInstance;
}

- (void)testAction:(id)sender {
    NSLog(@"MinimalHiddenGem: TestItem was clicked!");
    // You can add more functionality here later
}

+ (void)load {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    
    // Blacklist system processes - inject into applications only
    NSArray *blackList = @[@"com.apple.dock", @"com.apple.loginwindow", 
                          @"com.apple.Spotlight", @"com.apple.SystemUIServer", 
                          @"com.apple.screencaptureui", @"com.vmware.vmware-vmx"];
    if ([blackList containsObject:bundleID]) {
        return;
    }
    
    NSLog(@"MinimalHiddenGem: Loading into %@", bundleID);
    
    // Check macOS version for Sonoma compatibility
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    onSonomaOrHigher = (version.majorVersion >= 14);
    
    // Initialize test menu with proper target and action
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Create main menu
        hiddenGemMenu = [[NSMenu alloc] initWithTitle:@"HiddenGem"];
        
        // Create HiddenGem submenu item
        hiddenGemItem = [[NSMenuItem alloc] initWithTitle:@"HiddenGem" action:nil keyEquivalent:@""];
        hiddenGemSubmenu = [[NSMenu alloc] initWithTitle:@"HiddenGem"];
        hiddenGemItem.submenu = hiddenGemSubmenu;
        
        // Create TestItem for the submenu
        testItem = [[NSMenuItem alloc] initWithTitle:@"TestItem" action:@selector(testAction:) keyEquivalent:@""];
        [testItem setTarget:[MinimalHiddenGem sharedInstance]];
        
        // Add TestItem to the submenu
        [hiddenGemSubmenu addItem:testItem];
        
        // Add HiddenGem item to main menu
        [hiddenGemMenu addItem:hiddenGemItem];
        
        NSLog(@"MinimalHiddenGem: HiddenGem submenu initialized with TestItem");
    });
}

@end

// Use ZKSwizzleInterface like the working version
ZKSwizzleInterface(MinimalApp, NSApplication, NSResponder)
@implementation MinimalApp

- (CFArrayRef)_createDockMenu:(BOOL)enabled {
    NSLog(@"MinimalHiddenGem: _createDockMenu called for %@", [[NSBundle mainBundle] bundleIdentifier]);
    
    // Get original menu
    CFArrayRef originalMenu = ZKOrig(CFArrayRef, enabled);
    if (!originalMenu) {
        NSLog(@"MinimalHiddenGem: No original menu");
        return NULL;
    }
    
    // Create final menu
    CFMutableArrayRef finalMenu = CFArrayCreateMutable(0, 0, &kCFTypeArrayCallBacks);
    CFArrayAppendArray(finalMenu, originalMenu, CFRangeMake(0, CFArrayGetCount(originalMenu)));
    CFRelease(originalMenu);
    
    // Add our test menu if available
    if (hiddenGemMenu) {
        CFArrayRef flatTestMenu = nil;
        
        // Use appropriate _flattenMenu method based on macOS version
        if (onSonomaOrHigher) {
            flatTestMenu = [(NSApplication*)self _flattenMenu:hiddenGemMenu flatList:nil extraUpdateFlags:0x40000000];
        } else {
            flatTestMenu = [(NSApplication*)self _flattenMenu:hiddenGemMenu flatList:nil];
        }
        
        if (flatTestMenu) {
            CFArrayAppendArray(finalMenu, flatTestMenu, CFRangeMake(0, CFArrayGetCount(flatTestMenu)));
            CFRelease(flatTestMenu);
            NSLog(@"MinimalHiddenGem: Added TestItem to menu");
        }
    }
    
    return finalMenu;
}

@end
