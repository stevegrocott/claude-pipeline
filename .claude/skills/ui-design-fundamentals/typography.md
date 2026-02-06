# Typography

## Type Scale

Consistent sizes create hierarchy. Reference Material Design or HIG for platform-specific scales.

### Desktop/Web Scale

| Element | Size | Weight | Line Height |
|---------|------|--------|-------------|
| Display 1 | 72px | SemiBold | 1.1 |
| Display 2 | 64px | SemiBold | 1.1 |
| H1 | 56px | SemiBold | 1.2 |
| H2 | 48px | SemiBold | 1.2 |
| H3 | 40px | SemiBold | 1.25 |
| H4 | 32px | SemiBold | 1.3 |
| H5 | 24px | SemiBold | 1.3 |
| H6 | 20px | SemiBold | 1.4 |
| Subheadline | 20px | Regular | 1.4 |
| Title | 18px | SemiBold | 1.4 |
| Body Large | 16px | Medium | 1.5 |
| Body | 14px | Medium | 1.5 |
| Caption | 12-13px | Medium | 1.4 |
| Button Large | 16px | Bold | 1.25 |
| Button Small | 14px | Bold | 1.25 |

### Mobile Scale (iOS Reference)

| Style | Size | Weight |
|-------|------|--------|
| Large Title | 34px | Bold |
| Title 1 | 28px | Bold |
| Title 2 | 22px | Bold |
| Title 3 | 20px | Semibold |
| Headline | 17px | Semibold |
| Body | 17px | Regular |
| Callout | 16px | Regular |
| Subhead | 15px | Regular |
| Footnote | 13px | Regular |
| Caption 1 | 12px | Regular |
| Caption 2 | 11px | Regular |

## Font Weight Usage

| Weight | Use For |
|--------|---------|
| Bold (700) | CTAs, buttons, emphasis |
| SemiBold (600) | Headings, titles |
| Medium (500) | Body text, descriptions |
| Regular (400) | Secondary text, long-form |
| Light (300) | Rarely - large display only |

**Rule:** Don't use more than 2-3 weights per project.

## Line Height

| Content Type | Line Height |
|--------------|-------------|
| Headings | 1.1 - 1.25 |
| Body text | 1.4 - 1.6 |
| Buttons/Labels | 1.0 - 1.25 |
| Dense UI | 1.2 - 1.4 |

**Larger text = tighter line height**
**Smaller text = looser line height**

## Creating Hierarchy

Hierarchy guides the eye. Establish through:

### 1. Size Contrast
- Primary info: Largest
- Secondary: Medium
- Tertiary: Smallest
- Minimum 2-4px difference between levels

### 2. Weight Contrast
- Important: Bold/SemiBold
- Normal: Medium/Regular
- De-emphasized: Regular + lighter color

### 3. Color Contrast
- Primary text: High contrast (near black)
- Secondary: Medium contrast (gray)
- Tertiary: Lower contrast (light gray)
- Interactive: Brand color

### Example Hierarchy

```
SECTION LABEL          ← 12px, SemiBold, Primary color, uppercase
Page Title             ← 32px, SemiBold, Near black
Supporting subtitle    ← 16px, Regular, Medium gray
that adds context

Body text goes here    ← 14px, Medium, Dark gray
with normal content.

[Primary CTA]          ← 16px, Bold, White on primary
Learn more →           ← 14px, Medium, Primary color
```

## Spacing with Typography

### Text Block Spacing

| Relationship | Spacing |
|--------------|---------|
| Title + Description | 8-12px |
| Paragraph + Paragraph | 16-24px |
| Heading + Body | 12-20px |
| Section + Section | 40-64px |

### Optical Alignment

Text doesn't always align visually where it aligns mathematically:
- Round letters (O, C, G) extend slightly past baseline
- Pointed letters (A, V) may need slight adjustment
- Left-align text, not justify (improves readability)

## Font Pairing

### Safe Combinations

1. **Same family, different weights**
   - Heading: Inter Bold
   - Body: Inter Regular

2. **Serif + Sans-serif**
   - Heading: Playfair Display
   - Body: Source Sans Pro

3. **Geometric + Humanist**
   - Heading: Poppins
   - Body: Open Sans

### Rules for Pairing

- Max 2 font families
- Ensure contrast (don't pair similar fonts)
- Match x-height if possible
- Test at actual sizes

## Recommended Fonts

### Sans-Serif (Modern, Clean)

- **Inter** - Excellent for UI, free
- **SF Pro** - iOS system font
- **Roboto** - Android system font
- **Satoshi** - Modern, free (Fontshare)
- **DM Sans** - Friendly, free

### Serif (Elegant, Traditional)

- **Playfair Display** - Editorial
- **Merriweather** - Readable body text
- **Lora** - Balanced, versatile

### Monospace (Code, Data)

- **JetBrains Mono** - Developer favorite
- **SF Mono** - Apple system
- **Fira Code** - Ligatures

## Accessibility

### Minimum Sizes

- Body text: 14px minimum, 16px preferred
- Buttons: 14px minimum
- Captions: 12px minimum
- Never below 11px

### Contrast Requirements

| Text Size | Minimum Ratio |
|-----------|---------------|
| < 18px | 4.5:1 |
| ≥ 18px or 14px bold | 3:1 |
| AAA (ideal) | 7:1 |

### Readability Tips

- Line length: 45-75 characters
- Avoid all caps for body text
- Don't center long text blocks
- Sufficient paragraph spacing
- Avoid light fonts on light backgrounds

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Too many sizes | Stick to type scale |
| Random font sizes | Use defined scale |
| Low contrast text | Check with A11y tools |
| Tiny mobile text | 14px minimum body |
| Too many fonts | Max 2 families |
| Justified text | Left-align instead |
| All caps body | Reserve for labels |
