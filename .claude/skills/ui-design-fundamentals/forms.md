# Forms

## Core Principles

Forms collect information. Good forms:
- Minimize friction
- Prevent errors
- Provide clear feedback
- Only ask what's necessary

## Form Anatomy

```
┌─────────────────────────────────────┐
│ Label *                             │
│ ┌─────────────────────────────────┐ │
│ │ Placeholder text                │ │
│ └─────────────────────────────────┘ │
│ Helper text or error message        │
└─────────────────────────────────────┘
```

### Components

| Element | Purpose |
|---------|---------|
| Label | Identifies the field (always visible) |
| Input | Where user enters data |
| Placeholder | Example format (not a label replacement) |
| Helper text | Additional guidance |
| Error message | What's wrong + how to fix |

## Labels

### Always Visible

```
✅ Label above input (always visible)
┌─────────────────┐
│ Email address   │
│ ┌─────────────┐ │
│ │             │ │
│ └─────────────┘ │
└─────────────────┘

❌ Label as placeholder (disappears)
┌─────────────────┐
│ ┌─────────────┐ │
│ │ Email addr..│ │  ← Gone when typing
│ └─────────────┘ │
└─────────────────┘
```

### Floating Labels

Compromise that works:
```
Before focus:         After focus:
┌─────────────────┐   ┌─────────────────┐
│ ┌─────────────┐ │   │ Email           │ ← Moves up
│ │ Email       │ │   │ ┌─────────────┐ │
│ └─────────────┘ │   │ │ user@...    │ │
└─────────────────┘   │ └─────────────┘ │
                      └─────────────────┘
```

## Required vs Optional

### Mark Optional, Not Required

Most fields are required, so mark the exceptions:

```
✅ Better approach:
┌─────────────────┐
│ Email address   │
│ ┌─────────────┐ │
│ └─────────────┘ │
│                 │
│ Phone (optional)│
│ ┌─────────────┐ │
│ └─────────────┘ │
└─────────────────┘

❌ Asterisk overload:
┌─────────────────┐
│ Email *         │
│ Name *          │
│ Address *       │
│ City *          │
│ Phone           │
└─────────────────┘
```

**Why:** Asterisks create visual noise and anxiety. "Optional" is clearer.

## Input Types

Use correct input types for better UX:

| Data | Input Type | Benefit |
|------|------------|---------|
| Email | `type="email"` | Email keyboard on mobile |
| Phone | `type="tel"` | Number pad on mobile |
| Password | `type="password"` | Masked, show/hide toggle |
| Number | `type="number"` | Number pad, increment arrows |
| Date | `type="date"` | Native date picker |
| URL | `type="url"` | URL keyboard |

## Input Sizing

### Height

- Minimum: 44px (mobile), 40px (desktop)
- Recommended: 48px
- Consistent across all inputs

### Width

Match expected content length:

```
Short (Zip):     Long (Address):
┌──────────┐     ┌──────────────────────────────┐
│ 12345    │     │ 123 Main Street, Apt 4B     │
└──────────┘     └──────────────────────────────┘
```

### Placeholder Text

Show expected format:
```
Phone: (555) 123-4567
Date: MM/DD/YYYY
Credit Card: 1234 5678 9012 3456
```

## Input States

| State | Visual Treatment |
|-------|------------------|
| Default | Border: gray |
| Focus | Border: primary, outline ring |
| Filled | Border: gray, value visible |
| Error | Border: red, error message |
| Disabled | Background: light gray, cursor: not-allowed |
| Success | Border: green (optional), checkmark |

### Focus State (Required)

```css
input:focus {
  border-color: var(--primary);
  outline: 2px solid var(--primary-light);
  outline-offset: 2px;
}
```

## Validation

### Inline Validation

Validate as user types or on blur:

```
✅ Email validated on blur:
┌─────────────────────────────┐
│ Email                       │
│ ┌─────────────────────────┐ │
│ │ invalidemail            │ │ ← Red border
│ └─────────────────────────┘ │
│ ⚠️ Please enter valid email │ ← Specific message
└─────────────────────────────┘
```

### Error Messages

**Do:**
- Be specific: "Password must be 8+ characters"
- Be helpful: "Email format: name@example.com"
- Show near the field
- Use icon + color + text (not just color)

**Don't:**
- "Invalid input"
- "Error"
- "Please fix errors" (which ones?)

### Success States

Confirm valid input:
```
┌─────────────────────────────┐
│ Email                     ✓ │ ← Checkmark
│ ┌─────────────────────────┐ │
│ │ valid@email.com         │ │ ← Green border (optional)
│ └─────────────────────────┘ │
└─────────────────────────────┘
```

## Selection Controls

### When to Use What

| Control | Use When |
|---------|----------|
| Radio buttons | One choice from few options (2-5) |
| Checkboxes | Multiple choices allowed |
| Dropdown/Select | One choice from many options (5+) |
| Toggle | On/off binary choice |

### Radio Buttons

```
○ Option A
● Option B  ← Selected
○ Option C
```

- Mutually exclusive
- Always show all options
- One pre-selected (usually)

### Checkboxes

```
☑ Option A  ← Selected
☐ Option B
☑ Option C  ← Selected
```

- Multiple selections allowed
- Independent choices
- Can all be unchecked

### Toggles

```
Notifications  [====●]  On
Dark mode      [●====]  Off
```

- Immediate effect (no submit needed)
- Binary on/off
- Show current state clearly

## Multi-Step Forms

For long forms, break into steps:

```
Step 1        Step 2        Step 3
●─────────────○─────────────○
Personal      Address       Payment
```

### Guidelines

- Show progress indicator
- Allow going back
- Save progress
- Validate each step before proceeding
- Show summary before final submit

### Progress Indicators

```
Option 1: Steps
[1] → [2] → [3]

Option 2: Progress bar
████████░░░░░░░░ 50%

Option 3: Checklist
✓ Personal info
→ Address (current)
○ Payment
```

## Layout

### Vertical Stacking

```
✅ Vertical (easier to scan):
┌─────────────────────┐
│ First name          │
│ ┌─────────────────┐ │
│ └─────────────────┘ │
│ Last name           │
│ ┌─────────────────┐ │
│ └─────────────────┘ │
│ Email               │
│ ┌─────────────────┐ │
│ └─────────────────┘ │
└─────────────────────┘
```

### When to Use Horizontal

Only for related short fields:

```
┌───────────────────────────────────┐
│ First name        Last name       │
│ ┌─────────────┐   ┌─────────────┐ │
│ └─────────────┘   └─────────────┘ │
│                                   │
│ City       State    Zip           │
│ ┌───────┐  ┌────┐   ┌──────┐     │
│ └───────┘  └────┘   └──────┘     │
└───────────────────────────────────┘
```

### Button Placement

```
┌─────────────────────────────────┐
│ [Form fields...]                │
│                                 │
│              [Cancel] [Submit]  │ ← Primary on right
└─────────────────────────────────┘
```

## Accessibility

### Labels

- Every input needs a label
- Use `<label for="id">` association
- Don't rely on placeholder alone

### Keyboard Navigation

- Tab through all fields
- Enter submits form
- Escape closes modals
- Arrow keys for radio groups

### Error Announcement

- Use `aria-invalid="true"` on error
- Use `aria-describedby` for error messages
- Screen readers announce errors

### Touch Targets

- 44px minimum height
- Adequate spacing between fields (16px+)
- Large checkboxes/radios (24px+)

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Placeholder as label | Always show label |
| Generic errors | Be specific and helpful |
| Too many required fields | Only ask what's necessary |
| No inline validation | Validate on blur |
| Tiny touch targets | 44px minimum |
| Submit without feedback | Show loading, success, or error |
| Clearing form on error | Preserve user input |
| No focus states | Add visible focus ring |
