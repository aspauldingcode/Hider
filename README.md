# HiddenGem

A macOS tweak that allows you to remove Finder and Trash icons from the Dock, giving you more control over your Dock's appearance.

## Features

- **Remove Finder from Dock**: Hide the Finder icon while keeping it accessible via other means
- **Remove Trash from Dock**: Hide the Trash icon while maintaining full functionality
- **Context Menu Integration**: Right-click on Finder or Trash icons to toggle their persistence
- **Dynamic Detection**: Automatically detects and handles both Finder and Trash appropriately

## Installation

1. Install [Ammonia](https://github.com/Wowfunhappy/Ammonia) (macOS tweak injection framework)
2. Copy `libhiddengem.dylib` and `libhiddengem.dylib.blacklist` to your tweaks folder
3. Restart the Dock: `killall Dock`

## Usage

Right-click on the Finder or Trash icon in the Dock and select "Remove from Dock" to hide it. The functionality remains fully accessible through other means (Spotlight, Applications folder, etc.).

## Building

```bash
make clean
make
```

## Technical Details

HiddenGem works by:
- Swizzling Dock application methods to add custom menu items
- Managing dock persistence preferences for both `persistent-apps` (Finder) and `persistent-others` (Trash)
- Handling the special case of Trash which uses a different preference structure

## License

MIT License - see source files for details

## Author

Alex Spaulding
