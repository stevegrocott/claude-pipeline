# Hero Sections

## Purpose

The hero section:
- Creates first impression
- Communicates core value proposition
- Drives primary action
- Sets visual tone for site

## Above the Fold Checklist

Essential elements visible without scrolling:

1. **Clear headline** - What you offer
2. **Value proposition** - Why it matters
3. **Primary CTA** - What to do next
4. **Social proof** - Why trust you
5. **Relevant visual** - Product/brand imagery

## Anatomy

```
┌─────────────────────────────────────────────────────────────┐
│ [Nav bar]                                                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Headline That Grabs               ┌─────────────────┐    │
│   Attention Fast                    │                 │    │
│                                     │   Product       │    │
│   Supporting text that explains     │   Mockup        │    │
│   the value in 1-2 sentences.       │                 │    │
│                                     └─────────────────┘    │
│   [Primary CTA]  [Secondary CTA]                           │
│                                                             │
│   ⭐⭐⭐⭐⭐ Rated 5.0 by 1,500+ users                    │
│                                                             │
│   ↓ Scroll indicator / "How it works"                      │
└─────────────────────────────────────────────────────────────┘
```

## Headlines

### Characteristics

- **Clear:** No jargon, simple language
- **Specific:** What you do, not abstract
- **Benefit-focused:** What user gets
- **Emotional:** Tap into desires/pain points
- **Concise:** 6-12 words ideal

### Examples

| Weak | Strong |
|------|--------|
| "Welcome to Our Platform" | "Manage Your Money in Minutes" |
| "Next-Gen Solutions" | "Cut Your Accounting Time by 50%" |
| "The Best Tool" | "Design Beautiful Apps Without Code" |

### Hierarchy

```
SMALL LABEL / EYEBROW          ← 12-14px, uppercase, primary color
Main Headline Here             ← 40-72px, bold, high contrast
Supporting subheadline that    ← 18-24px, regular, lower contrast
adds context and detail
```

## Call-to-Actions

### Primary CTA

- Highest visual weight (filled button)
- Action-oriented verb: "Get Started", "Try Free", "Start Building"
- Creates urgency: "Start Free Trial", "Get Started Today"
- Large and prominent

### Secondary CTA

- Lower visual weight (outlined or text)
- Alternative path: "Watch Demo", "Learn More", "See Pricing"
- For less committed visitors

### CTA Placement

```
Left-aligned (F-pattern):      Center-aligned (Z-pattern):
┌──────────────────────┐       ┌──────────────────────┐
│ Headline             │       │      Headline        │
│ Subtitle             │       │      Subtitle        │
│                      │       │                      │
│ [CTA] [Secondary]    │       │   [CTA] [Secondary]  │
└──────────────────────┘       └──────────────────────┘
```

### CTA Text Examples

| Weak | Strong |
|------|--------|
| Submit | Get My Free Guide |
| Click Here | Start 14-Day Trial |
| Learn More | See How It Works |
| Sign Up | Create Free Account |

## Social Proof

### Types

| Type | Example |
|------|---------|
| Ratings | ⭐ 4.9/5.0 from 2,500 reviews |
| User count | Trusted by 50,000+ designers |
| Logos | "Used by teams at [Logos]" |
| Testimonial | "Best tool I've used" - Name |
| Awards | Product of the Year 2024 |

### Placement

```
Option 1: Below CTA
[Get Started]
⭐⭐⭐⭐⭐ 5.0 from 1,500+ users

Option 2: Logo bar below hero
─────────────────────────────
Trusted by teams at: [Logo] [Logo] [Logo]

Option 3: Testimonial snippet
"Game changer for our team"
— Sarah, Design Lead at Company
```

## Visual Patterns

### F-Pattern (Text-Heavy)

User scans:
1. Top horizontal line
2. Down left side
3. Second horizontal scan

**Best for:**
- Left-aligned content
- Multiple text elements
- Detailed information

```
┌─────────────────────────────────┐
│ ████████████████████            │ ← First scan
│ ████████████████                │
│ █████████                       │ ← Second scan
│ ████████████                    │
│ [CTA]                           │
└─────────────────────────────────┘
```

### Z-Pattern (Visual)

User scans:
1. Top left → top right
2. Diagonal to bottom left
3. Bottom left → bottom right

**Best for:**
- Center-aligned content
- Strong visuals
- Simple messaging

```
┌─────────────────────────────────┐
│ Logo ─────────────────────► Nav │
│          ↘                      │
│        Headline                 │
│          [CTA]                  │
│            ↘                    │
│ Social proof ─────────► Visual  │
└─────────────────────────────────┘
```

## Hero Visuals

### Types

| Visual | Best For |
|--------|----------|
| Product mockup | SaaS, apps, software |
| Photography | Lifestyle, services |
| Illustration | Abstract concepts, friendly brands |
| Video | Complex products, emotional appeal |
| Animation | Interactive, engaging |

### Guidelines

- Support the message, don't distract
- High quality only
- Responsive (works on mobile)
- Fast loading (optimize images)
- Accessible (alt text, captions)

### Layout Options

```
Split (50/50):           Asymmetric:
┌─────────┬─────────┐    ┌──────────────────┐
│  Text   │  Image  │    │ Text        Img  │
│  CTA    │         │    │ CTA              │
└─────────┴─────────┘    └──────────────────┘

Background image:        Overlapping:
┌─────────────────┐      ┌─────────────────┐
│ ░░░░░░░░░░░░░░░ │      │ Text            │
│ ░░ Text ░░░░░░░ │      │ CTA   ┌───────┐ │
│ ░░ CTA ░░░░░░░░ │      │       │ Image │ │
└─────────────────┘      └───────┴───────┘
```

## Teasing Continuation

Hint that content continues below:

### Techniques

```
1. Partial element visible:
┌─────────────────────┐
│     Hero content    │
│─────────────────────│
│ ▀▀▀ Partial card ▀▀ │ ← Cut off, invites scroll
└─────────────────────┘

2. Arrow or indicator:
[Hero content]
        ↓
  How it works

3. Text link:
[Hero content]
See how it works →
```

## Spacing

### Internal Spacing

| Element | Spacing |
|---------|---------|
| Headline to subheadline | 16-24px |
| Subheadline to CTA | 24-32px |
| CTA to social proof | 16-24px |
| Hero padding | 64-120px vertical |

### Hero Height

- **Minimum:** Viewport height minus nav (100vh - 80px)
- **With continuation hint:** ~90vh (shows next section)
- **Mobile:** Can be taller (scroll is expected)

## Responsive Considerations

### Mobile Adjustments

- Stack content vertically
- Reduce headline size (32-40px)
- Full-width CTAs
- Move image below or remove
- Smaller vertical padding (48-80px)

```
Desktop:                 Mobile:
┌─────────┬─────────┐    ┌─────────────────┐
│  Text   │  Image  │    │      Image      │
│  CTA    │         │    │      Text       │
└─────────┴─────────┘    │     [CTA]       │
                         └─────────────────┘
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Vague headline | Be specific about value |
| No clear CTA | One prominent primary action |
| Too much text | Simplify, move details below |
| Slow loading image | Optimize, use lazy loading |
| No social proof | Add ratings, logos, or testimonials |
| Buried CTA | Above the fold, high contrast |
| Generic stock photo | Use product shots or custom imagery |
| No mobile optimization | Design mobile-first |
