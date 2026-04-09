# uploader-helper

Passes data between blood glucose meters and the Tidepool Uploader Helper web extension

When you use `git tag` and push, GitHub Actions should create a new release with assets. 

## To publish

First, get `helper.exe` from the GitHub release and sign it with an EV code signing certificate (i.e, hardware key):

`signtool sign /v /tr http://timestamp.digicert.com /td sha256 /fd sha256 /s my /n "Tidepool Project" /sha1 <tidepool_cert_thumbprint> helper.exe`

You'll need the hardware token and the password in 1Password - if the SafeNet client does not prompt you for a password, you're not using the right certificate. Also replace the thumbprint/serial with that of the certificate you're using, and remember to install the root certs on the token when you're doing this for the first time.

You can find the cert thumbprint by:

- right-clicking on the SafeNet Authentication Client in the task bar
- selecting "Certificate Information", double-clicking the certificate,
- clicking on the Details tab, and
- looking at the Thumbprint field.

Then copy `helper.exe` to the `resources/win` folder in the uploader repo (for Electron Uploader) and to the windows-driver repo (`https://github.com/tidepool-org/windows-driver/tree`) in the `helper` folder (for Uploader-in-Web).

## To test

Run `node testing.js` to test the compiled helper binary for your current OS:
- Windows → tests `helper.exe`
- macOS ARM64 → tests `helper-macos-arm64`
- macOS x86_64 → tests `helper-macos-x64`
- Linux → tests `helper-linux`
