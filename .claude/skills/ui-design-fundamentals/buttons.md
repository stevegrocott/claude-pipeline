# Buttons

## Core Principles

Buttons must be:
- **Identifiable** - Looks clickable
- **Findable** - Easy to spot
- **Clear** - Obvious what happens when clicked

## Button Anatomy

```
┌─────────────────────────────────┐
│  [icon]  Button Label  [icon]  │
│     ↑         ↑          ↑     │
│  optional   required   optional │
└─────────────────────────────────┘
     ←─── horizontal padding ───→
              (16-24px)
```

### Dimensions

| Context | Min Height | Padding (H) | Padding (V) |
|---------|------------|-------------|-------------|
| Desktop | 40px | 16-24px | 10-12px |
| Mobile | 44-48px | 16-24px | 12-16px |
| Small | 32px | 12-16px | 6-8px |

**Rule:** Horizontal padding ≈ 2x vertical padding

### Text

| Size | Font Size | Weight |
|------|-----------|--------|
| Large | 16-18px | Bold |
| Default | 14-16px | Bold/SemiBold |
| Small | 12-14px | SemiBold |

## Button Types

### Primary (Filled)

```css
background: var(--primary);
color: white;
```

- Highest visual weight
- Main CTA on page
- Use sparingly (1-2 per view)

### Secondary (Outlined/Ghost)

```css
background: transparent;
border: 1px solid var(--primary);
color: var(--primary);
```

- Medium visual weight
- Alternative actions
- "Learn more", "Watch video"

### Tertiary (Text/Link)

```css
background: transparent;
color: var(--primary);
/* Optional: text-decoration: underline; */
```

- Lowest visual weight
- Minor actions
- Navigation, cancel

### Destructive

```css
background: var(--error);
color: white;
```

- For delete, remove, cancel subscription
- Requires confirmation for critical actions

## Button States

| State | Visual Change |
|-------|---------------|
| Default | Base styling |
| Hover | Darken 10%, cursor pointer |
| Focus | Outline ring (accessibility) |
| Active/Pressed | Darken 15%, slight scale down |
| Disabled | 50% opacity, no pointer |
| Loading | Spinner, disabled interaction |

### State Examples

```css
/* Hover */
.button:hover {
  background: color-mix(in srgb, var(--primary) 90%, black);
}

/* Active */
.button:active {
  transform: scale(0.98);
}

/* Disabled */
.button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

/* Focus (accessibility) */
.button:focus-visible {
  outline: 2px solid var(--primary);
  outline-offset: 2px;
}
```

## Visual Hierarchy

Arrange by importance:

```
[Primary CTA]  [Secondary]  Tertiary link
    ↑              ↑            ↑
  Most         Medium        Least
important    important     important
```

### Alignment Creates Hierarchy

Place most important action where users naturally look:
- **LTR languages:** Right side = primary action
- **Modals:** Primary on right, Cancel on left
- **Forms:** Submit button aligned with inputs

```
┌─────────────────────────────────┐
│  Form fields...                 │
│                                 │
│            [Cancel] [Submit]    │
└─────────────────────────────────┘
```

## Icons in Buttons

### Icon Position

```
✅ [🔍] Search    - Icon leads (describes action)
✅ Download [↓]   - Icon trails (shows direction)
❌ [🔍] Search [→] - Too many icons
```

**Guidelines:**
- Lead with icon when it describes the action
- Trail with icon when showing direction/result
- Don't use icons that don't add meaning

### Icon Sizing

- Icon should be similar to text line-height
- 16-20px for standard buttons
- 12-14px for small buttons
- Maintain consistent spacing (8px from text)

## Button Text (CTAs)

### Do

- Use action verbs: "Get Started", "Download PDF", "Create Account"
- Be specific: "Add to Cart" not "Submit"
- Create urgency (when appropriate): "Get Started Now"
- Keep short: 1-3 words ideal

### Don't

- "Click Here" (not accessible, not descriptive)
- "Submit" (too generic)
- "Yes" / "No" (use descriptive labels)
- Long sentences

### Examples

| Bad | Good |
|-----|------|
| Click Here | Download Report |
| Submit | Create Account |
| Yes | Delete Item |
| No | Keep Item |
| Learn More | See Pricing |

## Contrast & Accessibility

### Color Contrast

- Button background vs page: Should stand out
- Button text vs button background: Min 4.5:1
- Don't use color alone to convey meaning

### Focus States

Required for keyboard navigation:

```css
.button:focus-visible {
  outline: 2px solid var(--focus-color);
  outline-offset: 2px;
}
```

### Touch Targets

| Platform | Minimum Size |
|----------|--------------|
| iOS | 44x44px |
| Android | 48x48px |
| Desktop | 32px height |

**Invisible padding:** If button looks small but needs large tap target:

```css
.button {
  position: relative;
  padding: 8px 16px; /* Visual padding */
}

.button::before {
  content: '';
  position: absolute;
  inset: -8px; /* Extends tap target */
}
```

## Button Placement

### Mobile Considerations

```
┌─────────────────────┐
│                     │
│    Easy reach       │ ← Natural thumb zone
│    ┌───────────┐    │
│    │  Primary  │    │
│    └───────────┘    │
│    ━━━━━━━━━━━━━    │ ← Tab bar
└─────────────────────┘
```

- Primary CTAs in thumb-friendly zone (bottom half)
- Destructive/back buttons harder to reach (prevent accidents)
- Consider one-handed use

### Desktop Considerations

- Align with form fields
- Primary on right (for LTR)
- Consistent positioning across views

## Styling Variations

### Corner Radius

| Style | Radius | Feeling |
|-------|--------|---------|
| Sharp | 0-2px | Professional, serious |
| Rounded | 4-8px | Balanced, modern |
| Pill | 50%/full | Friendly, playful |

### Enhancements

**Gradient:**
```css
background: linear-gradient(180deg, #5a67d8 0%, #4c51bf 100%);
```

**Inner shadow (3D effect):**
```css
box-shadow: inset 0 1px 0 rgba(255,255,255,0.2);
```

**Stroke:**
```css
border: 1px solid rgba(0,0,0,0.1);
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Too many primary buttons | One primary per view |
| Tiny tap targets | 44px minimum |
| Low contrast text | Check with contrast tools |
| No hover/focus states | Add all interactive states |
| Vague labels | Use specific action verbs |
| Inconsistent styling | Create button components |
| Disabled without reason | Show why it's disabled |
