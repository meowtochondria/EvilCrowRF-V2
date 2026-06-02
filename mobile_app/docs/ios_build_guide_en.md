# 🍎 iOS Build Guide for Windows Developers

## 📋 Mandatory Requirements for iOS

- **macOS** (only on Mac can you compile iOS applications)
- **Xcode** (latest version)
- **Flutter** (installed on Mac)
- **Apple Developer Account** (for distribution)

## 🖥️ Solutions for Windows Developers

### 1. **GitHub Actions (Free) - Recommended**

#### Setup:
1. Upload your code to a GitHub repository
2. GitHub will automatically trigger an iOS build on each push
3. Built artifacts will be available in the Actions section

#### Commands to run:
```bash
# Add files to git
git add .
git commit -m "Add iOS build configuration"
git push origin main

# Check build status in GitHub Actions
```

### 2. **Codemagic (Paid, but convenient)**

#### Setup:
1. Register at [codemagic.io](https://codemagic.io)
2. Connect your GitHub repository
3. Configure Apple Developer certificates
4. Start the build

#### Advantages:
- Automatic build on every push
- Code signing support
- TestFlight publishing
- GitHub integration

### 3. **macOS Virtual Machine**

#### Requirements:
- VMware Workstation Pro or VirtualBox
- macOS ISO image (legally obtaining is difficult)
- Minimum 8GB RAM, 50GB free space

#### Setup:
```bash
# On the Mac VM install:
# 1. Xcode from the App Store
# 2. Flutter SDK
# 3. CocoaPods: sudo gem install cocoapods

# Then run:
cd mobile_app
flutter pub get
flutter build ios
```

### 4. **Cloud Mac Services**

#### Available services:
- **MacStadium** - $0.50/hour
- **MacinCloud** - from $1/hour
- **AWS EC2 Mac instances** - from $1.083/hour

#### Example for AWS:
```bash
# Connect to Mac instance
ssh -i key.pem ec2-user@your-mac-instance

# Install Flutter and Xcode
# Build the app
flutter build ios
```

## 🚀 Step-by-Step Guide for GitHub Actions

### Step 1: Prepare the repository
```bash
# In the mobile_app folder
git init
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/yourusername/yourrepo.git
git push -u origin main
```

### Step 2: Check the build
1. Go to your GitHub repository
2. Open the Actions tab
3. Wait for the iOS build to complete

### Step 3: Download artifacts
1. In Actions, find the completed build
2. Click on the build
3. Download the artifacts (iOS build)

## 📱 Building for Different Purposes

### Debug build (for testing):
```bash
flutter build ios --debug
```

### Release build (for distribution):
```bash
flutter build ios --release
```

### Archive (for App Store):
```bash
flutter build ios --release
cd ios
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release -destination generic/platform=iOS -archivePath build/Runner.xcarchive clean archive
```

## 🔐 Code Signing

### For development:
```bash
# Automatic signing
flutter build ios --debug
```

### For distribution:
1. Get an Apple Developer Account ($99/year)
2. Create certificates in Apple Developer Console
3. Configure provisioning profiles
4. Use Codemagic or GitHub Actions with certificates

## 📦 Build Output

After a successful build you will get:
- **Debug**: `.app` file for device installation
- **Release**: `.ipa` file for TestFlight/App Store
- **Archive**: `.xcarchive` for Xcode

## 🆘 Troubleshooting

### Error "No iOS development team specified":
```bash
# Open ios/Runner.xcodeproj in Xcode
# In Signing & Capabilities select a Team
```

### Error "Code signing is required":
```bash
# Use --no-codesign for testing
flutter build ios --no-codesign
```

### Error "Provisioning profile not found":
```bash
# Configure provisioning profiles in Apple Developer Console
# Or use automatic signing in Xcode
```

## 💡 Recommendations

1. **Start with GitHub Actions** - it's free and automatic
2. **For serious development** use Codemagic
3. **For frequent builds** consider cloud Mac services
4. **Always test** on real iOS devices

## 🔗 Useful Links

- [Flutter iOS Deployment](https://flutter.dev/docs/deployment/ios)
- [Apple Developer Documentation](https://developer.apple.com/documentation/)
- [GitHub Actions Flutter](https://github.com/marketplace/actions/flutter-action)
- [Codemagic Flutter](https://codemagic.io/flutter/)
