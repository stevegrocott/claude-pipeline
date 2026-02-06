# Modals and Dropdowns

## Modals

### When to Use

**Do use modals for:**
- Critical confirmations (delete, cancel subscription)
- Focused tasks (compose message, quick edit)
- Important information requiring acknowledgment
- Multi-step wizards that need focus

**Don't use modals for:**
- Content that could be on the page
- Non-critical information
- Long forms (use a page instead)
- Frequent interactions (annoying)

### Modal Anatomy

```
┌─────────────────────────────────────────┐
│  Modal Title                        ✕   │
├─────────────────────────────────────────┤
│                                         │
│  Modal content goes here. This can      │
│  include text, forms, or other UI       │
│  elements.                              │
│                                         │
├─────────────────────────────────────────┤
│                    [Cancel]  [Confirm]  │
└─────────────────────────────────────────┘
```

### Components

| Element | Required | Purpose |
|---------|----------|---------|
| Title | Yes | Describes purpose |
| Close button (X) | Yes | Escape route |
| Content | Yes | Main information/form |
| Actions | Usually | Confirm/Cancel buttons |
| Overlay | Yes | Focus attention |

### Sizing

| Size | Width | Use For |
|------|-------|---------|
| Small | 400px | Simple confirmations |
| Medium | 500-600px | Forms, content |
| Large | 800px | Complex content |
| Full | 90% viewport | Wizards, extensive forms |

### Close Methods

Users should be able to close via:
1. **X button** - Top right corner
2. **Cancel button** - In footer
3. **Click overlay** - Click outside modal
4. **Escape key** - Keyboard shortcut

### Confirmation Dialogs

For destructive actions:

```
┌─────────────────────────────────────────┐
│  Delete Account                     ✕   │
├─────────────────────────────────────────┤
│                                         │
│  Are you sure you want to delete        │
│  your account? This cannot be undone.   │
│                                         │
├─────────────────────────────────────────┤
│                 [Keep Account] [Delete] │
│                      ↑            ↑     │
│                  Secondary    Destructive│
└─────────────────────────────────────────┘
```

**Guidelines:**
- Clear, specific question
- Explain consequences
- Use descriptive button labels (not Yes/No)
- Destructive action = red button
- Safe action = primary position

### Multi-Step Modals

```
┌─────────────────────────────────────────┐
│  Import Data                        ✕   │
├─────────────────────────────────────────┤
│  [1. Upload] → [2. Map] → [3. Confirm]  │
│       ●           ○            ○        │
├─────────────────────────────────────────┤
│                                         │
│  Drag and drop your file here           │
│  or [Choose file]                       │
│                                         │
├─────────────────────────────────────────┤
│  [Cancel]                       [Next]  │
└─────────────────────────────────────────┘
```

- Show progress indicator
- Allow going back
- Clear step labels
- Validate before proceeding

### Loading States

```
┌─────────────────────────────────────────┐
│  Processing...                          │
├─────────────────────────────────────────┤
│                                         │
│            ⟳ Loading...                 │
│                                         │
│    Please wait while we process         │
│    your request.                        │
│                                         │
└─────────────────────────────────────────┘
```

- Disable close during critical operations
- Show progress if possible
- Provide feedback

---

## Dropdowns

### When to Use

- More than 5 options
- Space is limited
- Options are predictable
- Single selection (usually)

### Standard Dropdown

```
Closed:                    Open:
┌─────────────────────┐    ┌─────────────────────┐
│ Select option     ▼ │    │ Select option     ▲ │
└─────────────────────┘    ├─────────────────────┤
                           │ Option 1            │
                           │ Option 2    ✓       │ ← Selected
                           │ Option 3            │
                           │ Option 4            │
                           └─────────────────────┘
```

### Dropdown States

| State | Visual |
|-------|--------|
| Default | Border: gray, text: placeholder |
| Hover | Border: darker |
| Open | Border: primary, dropdown visible |
| Selected | Display selected value |
| Disabled | Gray background, no interaction |
| Error | Border: red, error message |

### Multi-Select Dropdown

```
┌─────────────────────────────┐
│ Toppings (3 selected)     ▼ │
├─────────────────────────────┤
│ ☑ Pepperoni                 │
│ ☑ Mushrooms                 │
│ ☐ Olives                    │
│ ☑ Extra Cheese              │
│ ☐ Onions                    │
└─────────────────────────────┘
```

- Checkboxes for each option
- Show count of selected
- Allow deselecting
- Consider "Select All" / "Clear"

### Long Lists

For many options:

```
┌─────────────────────────────┐
│ 🔍 Search countries...      │
├─────────────────────────────┤
│ Afghanistan                 │
│ Albania                     │
│ Algeria                     │
│ ...                         │ ← Scrollable
│ ▼ Scroll indicator          │
└─────────────────────────────┘
```

- Add search/filter
- Scrollable container
- Show scroll indicator
- Consider modal for mobile

### Dropdown Visual Design

```css
.dropdown-menu {
  background: white;
  border: 1px solid #e5e7eb;
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
  max-height: 300px;
  overflow-y: auto;
}

.dropdown-item {
  padding: 12px 16px;
  cursor: pointer;
}

.dropdown-item:hover {
  background: #f3f4f6;
}

.dropdown-item.selected {
  background: #eff6ff;
  color: var(--primary);
}
```

### Nested Dropdowns

```
┌─────────────────────┐
│ Edit               │
│ View              →│────┌─────────────────┐
│ Insert            →│    │ Zoom In         │
│ Format             │    │ Zoom Out        │
└─────────────────────┘    │ Full Screen     │
                           └─────────────────┘
```

- Arrow indicates submenu
- Open on hover or click
- Clear visual hierarchy
- Limit nesting depth (max 2 levels)

### Keyboard Shortcuts in Dropdowns

```
┌─────────────────────────┐
│ Undo              ⌘Z    │
│ Redo              ⇧⌘Z   │
│ ─────────────────────── │
│ Cut               ⌘X    │
│ Copy              ⌘C    │
│ Paste             ⌘V    │
└─────────────────────────┘
```

- Right-align shortcuts
- Use standard symbols
- Consistent formatting

---

## Accordions

### When to Use

- FAQ sections
- Settings/preferences
- Collapsible content
- Space-constrained areas

### Anatomy

```
Closed:
┌─────────────────────────────────────────┐
│ Section Title                         + │
└─────────────────────────────────────────┘

Open:
┌─────────────────────────────────────────┐
│ Section Title                         − │
├─────────────────────────────────────────┤
│ Content goes here. This can be          │
│ multiple lines of text or other         │
│ elements like lists or forms.           │
└─────────────────────────────────────────┘
```

### Behavior Options

**Single open:**
- Only one section open at a time
- Opening one closes others
- Best for limited space

**Multiple open:**
- Any number can be open
- Independent toggles
- Best for reference content

### Visual Indicators

```
Chevron:    +/-:         Arrow:
▶ Closed    + Closed     → Closed
▼ Open      − Open       ↓ Open
```

Animate the icon rotation for polish.

---

## Accessibility

### Modals

```html
<div role="dialog" aria-modal="true" aria-labelledby="modal-title">
  <h2 id="modal-title">Modal Title</h2>
  <!-- Content -->
</div>
```

- Focus trap (Tab stays in modal)
- Return focus on close
- Escape key closes
- Screen reader announcement

### Dropdowns

```html
<button aria-haspopup="listbox" aria-expanded="false">
  Select option
</button>
<ul role="listbox">
  <li role="option" aria-selected="true">Option 1</li>
  <li role="option">Option 2</li>
</ul>
```

- Arrow keys navigate
- Enter/Space selects
- Escape closes
- Type-ahead search

### Accordions

```html
<button aria-expanded="false" aria-controls="content-1">
  Section Title
</button>
<div id="content-1" hidden>
  Content here
</div>
```

- Announce expanded/collapsed
- Arrow keys navigate headers
- Enter toggles

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| No close button | Always provide X and overlay click |
| No escape key | Add keyboard handler |
| Focus not trapped | Implement focus trap |
| Dropdown too long | Add search, limit height |
| Yes/No buttons | Use descriptive labels |
| Modal for everything | Use inline content when possible |
| No loading state | Show progress for async operations |
