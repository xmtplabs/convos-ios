# Guidebook

Manage the UIGuidebook visual component catalog.

## Usage

```
/guidebook scan
```

## Commands

### scan

Scan the codebase for SwiftUI views not yet documented in the UIGuidebook.

## Instructions for `/guidebook scan`

### Step 1: Find All SwiftUI Views in Convos App

Search for structs conforming to `View` in the main app:

```bash
# Find all View-conforming structs
grep -r "struct.*: View" Convos/ --include="*.swift" -l
```

For each file found, extract the view names:
```bash
grep -E "^struct [A-Z][a-zA-Z0-9]*:.*View" Convos/ -r --include="*.swift" -h | sed 's/struct \([A-Za-z0-9]*\).*/\1/'
```

### Step 2: Find Views Already in UIGuidebook

Search the UIGuidebook category files for documented components:

```bash
# Find ComponentShowcase and ScreenShowcase usages
grep -E "(ComponentShowcase|ScreenShowcase|CodeNameLabel)\(" UIGuidebook/Categories/*.swift -h
```

Also check the component hierarchies in ViewsGuidebookView.swift:
```bash
grep -E '\.init\(name: "' UIGuidebook/Categories/ViewsGuidebookView.swift
```

### Step 3: Compare and Report

Create a report with these sections:

#### Shared Views (`Convos/Shared Views/`)
Views meant to be reused across the app. **High priority** for guidebook.

#### Design System (`Convos/Design System/`)
Design tokens, styles, and foundational components. **High priority**.

#### Feature Views (other directories)
Screen-level views and feature-specific components. **Medium priority** - document main screens and key reusable components.

### Step 4: Output Format

Report the findings in this format:

```
## UIGuidebook Scan Results

### Already Documented (X views)
✓ MonogramView (Avatars)
✓ InfoView (Views > Sheet Views)
✓ HoldToConfirmButton (Buttons)
...

### Missing from Guidebook

**High Priority (Shared Views & Design System):**
- FlowLayout (Convos/Shared Views/FlowLayout.swift)
- SomeNewComponent (Convos/Design System/Components/SomeNewComponent.swift)

**Main Screens (for Views category hierarchies):**
- ProfileView (Convos/Profile/ProfileView.swift)
- SettingsDetailView (Convos/App Settings/SettingsDetailView.swift)

**Other Views (lower priority):**
- SomeFeatureView (Convos/Some Feature/SomeFeatureView.swift)
...

### Recommendations
1. Add FlowLayout to Containers category
2. Update ConversationsView hierarchy in Views category
3. Consider adding ProfileView to main screens section
```

### Step 5: Filtering

Exclude these from the scan:
- Preview providers (`*_Previews` structs)
- Private/internal helper views (views only used within one file)
- Test files

Focus on:
- Public/reusable views in `Shared Views/`
- Design system components
- Top-level screen views (the main view in each feature folder)

## Examples

**Scan for missing components:**
```
User: /guidebook scan
Claude: Scans Convos/ for View structs, compares with UIGuidebook,
        reports which views are missing and recommends which to add
```

**After adding new shared view:**
```
User: I just added a new ToastView to Shared Views
User: /guidebook scan
Claude: Shows ToastView as missing from guidebook,
        recommends adding to Feedback category
```
