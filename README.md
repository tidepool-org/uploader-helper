# uploader-helper

Passes data between blood glucose meters and the Tidepool Uploader Helper web extension

When you use `git tag` and push, GitHub Actions should create a new release with assets. 

## To publish

Copy `helper.exe` from the GitHub release to `https://github.com/tidepool-org/windows-driver/tree/master/helper`

## To test

Run `node testing.js` to test the compiled helper binary for your current OS:
- Windows → tests `helper.exe`
- macOS ARM64 → tests `helper-macos-arm64`
- macOS x86_64 → tests `helper-macos-x64`
- Linux → tests `helper-linux`
