# UIGuidebook

A standalone app target that serves as a visual component catalog for designers. Run this app on the simulator to see all UI components with their exact Swift code names.

## When to Update UIGuidebook

Update the UIGuidebook when:

1. **New shared UI component created** - Any new view added to `Convos/Shared Views/` or `Convos/Design System/` should be showcased
2. **New button style added** - Add to `ButtonsGuidebookView.swift`
3. **New design tokens added** - Colors, spacing, corner radius, or fonts in `DesignConstants.swift`
4. **Main app screens significantly changed** - Update the component hierarchies in `ViewsGuidebookView.swift`
5. **New reusable sheet/modal created** - Add to the Sheet Views section in `ViewsGuidebookView.swift`

## How to Add Components

### Adding a New Standalone Component

1. **Identify the category** - Buttons, Text Inputs, Avatars, Containers, Feedback, Animations, Views, or Design Tokens

2. **Edit the appropriate category view** in `UIGuidebook/Categories/`:
   ```swift
   private var myNewComponentSection: some View {
       ComponentShowcase(
           "MyComponentName",  // Exact Swift type name
           description: "Brief description of what it does"
       ) {
           // Live component with sample data
           MyComponent(param: "value")
       }
   }
   ```

3. **Add the section to the view's body** in the appropriate VStack

4. **If the component needs shared files**, add them to the Ruby script (see below)

### Adding Shared Files from Main App

The UIGuidebook target shares some files from the main Convos app. To add new shared files:

1. Edit `.claude/scripts/add-uiguidebook-target.rb`

2. Add the file path to the `shared_files` array:
   ```ruby
   shared_files = [
     # ... existing files
     'Convos/Shared Views/MyNewComponent.swift',
   ]
   ```

3. Run the Ruby script to update the Xcode project:
   ```bash
   ruby .claude/scripts/add-uiguidebook-target.rb
   ```

4. Build and run to verify

### Components Requiring Stubs

Some main app components have ConvosCore dependencies. For these:

1. Create stub types in `UIGuidebook/Utilities/ViewStubs.swift`
2. Or show static visual representations instead of live components (see `ViewsGuidebookView.swift` for examples)

## File Structure

```
UIGuidebook/
├── UIGuidebookApp.swift              # @main entry point
├── Info.plist
├── Navigation/
│   ├── GuidebookRootView.swift       # Main navigation list
│   └── ComponentRegistry.swift       # Category enum with destinations
├── Categories/
│   ├── ButtonsGuidebookView.swift
│   ├── TextInputsGuidebookView.swift
│   ├── AvatarsGuidebookView.swift
│   ├── ContainersGuidebookView.swift
│   ├── FeedbackGuidebookView.swift
│   ├── AnimationsGuidebookView.swift
│   ├── ViewsGuidebookView.swift      # Main screens + sheet views
│   └── DesignTokensGuidebookView.swift
├── Components/
│   ├── CodeNameLabel.swift           # Monospace label for type names
│   └── ComponentShowcase.swift       # Wrapper for showcasing components
└── Utilities/
    ├── Log.swift                     # Logging stub
    └── ViewStubs.swift               # Stubs for ConvosCore types
```

## Building

```bash
# Build and run in simulator
xcodebuild -project Convos.xcodeproj -scheme UIGuidebook -sdk iphonesimulator

# Or use the MCP tool
build_run_sim  # with UIGuidebook scheme selected
```

## Adding a New Category

1. Add a case to `ComponentCategory` enum in `ComponentRegistry.swift`:
   ```swift
   case myCategory = "My Category"
   ```

2. Add the system image, description, and destination view

3. Create `MyGuidebookView.swift` in `Categories/`

4. Add the new file to the Ruby script's categories section

5. Run the Ruby script to update the Xcode project

## Conventions

- **Always show exact Swift type names** using `CodeNameLabel`
- **Make buttons full width** for consistency
- **Show multiple states** when a component has them (disabled, loading, etc.)
- **Include brief descriptions** explaining when to use the component
- **Group related components** within a category view
