# Shadows and Depth

## Why Shadows Matter

Shadows create:
- **Depth** - Layered interface feeling
- **Hierarchy** - Elevated = important
- **Realism** - Mimics physical world
- **Focus** - Draws attention to floating elements

## Elevation Levels

| Level | Use | Y-Offset | Blur |
|-------|-----|----------|------|
| 0 | Flat elements | 0 | 0 |
| 1 | Cards, buttons | 2-4px | 4-8px |
| 2 | Dropdowns, raised cards | 4-8px | 8-16px |
| 3 | Modals, dialogs | 8-16px | 16-24px |
| 4 | Popovers, tooltips | 16-24px | 24-32px |

Higher elevation = larger offset + more blur + lower opacity

## Shadow Recipes

### Subtle Card Shadow

```css
box-shadow: 0 2px 4px rgba(0, 0, 0, 0.08);
```

### Standard Elevation

```css
box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
```

### Soft, Natural Shadow

```css
/* Two layers for more natural look */
box-shadow:
  0 10px 15px rgba(0, 0, 0, 0.04),
  0 2px 4px rgba(0, 0, 0, 0.08);
```

### Modal/Dialog Shadow

```css
box-shadow: 0 16px 32px rgba(0, 0, 0, 0.15);
```

### Colored/Material Reflection

```css
/* Use the element's background color */
background: #7949FF;
box-shadow: 0 15px 20px rgba(121, 73, 255, 0.3);
```

### Sharp/Retro Shadow

```css
/* No blur for sharp edge */
box-shadow: 4px 4px 0 rgba(0, 0, 0, 1);
```

## Shadow Properties

### Offset (X, Y)

- **X:** Horizontal offset (usually 0)
- **Y:** Vertical offset (2-24px typical)
- Larger Y = higher elevation feeling

### Blur

- Soft shadows: High blur (15-30px)
- Sharp shadows: Low blur (2-8px)
- Softer = more natural, higher light source

### Spread

- Usually 0 or negative
- Positive spread = larger shadow
- Negative spread = tighter shadow

### Color & Opacity

| Context | Opacity |
|---------|---------|
| Subtle | 4-8% |
| Standard | 10-15% |
| Strong | 20-30% |
| Colored | 20-40% |

**Tip:** Use dark blue (#0a1929) instead of black for softer shadows.

## Multiple Shadows

Layer shadows for more realistic depth:

```css
box-shadow:
  /* Ambient - soft, wide */
  0 10px 20px rgba(0, 0, 0, 0.04),
  /* Direct - sharper, closer */
  0 2px 6px rgba(0, 0, 0, 0.08);
```

### Why Multiple Shadows?

Real-world shadows have:
- Soft ambient light (wide, diffuse)
- Direct light source (sharper, more defined)

Combining both = more natural appearance.

## Direction

### Consistent Light Source

All shadows should come from same direction:
- Standard: Light from above (Y positive)
- Consistent across all elements

```
❌ Mixed directions (confusing)
┌───┐  ┌───┐  ┌───┐
│ ▼ │  │ ► │  │ ▲ │
└───┘  └───┘  └───┘

✅ Consistent (natural)
┌───┐  ┌───┐  ┌───┐
│ ▼ │  │ ▼ │  │ ▼ │
└───┘  └───┘  └───┘
```

## Inner Shadows

Create depth/inset effects:

```css
/* Subtle inner highlight */
box-shadow: inset 0 2px 4px rgba(255, 255, 255, 0.1);

/* Pressed/inset button */
box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
```

**Use for:**
- Input fields (subtle depth)
- Pressed button states
- Toggle switches
- Progress bars

## Dark Mode Shadows

Shadows don't work well on dark backgrounds. Alternatives:

### 1. Lighter Overlays/Glows

```css
/* Light glow instead of shadow */
box-shadow: 0 0 20px rgba(255, 255, 255, 0.1);
```

### 2. Border Highlights

```css
border: 1px solid rgba(255, 255, 255, 0.1);
```

### 3. High-Opacity Dark Shadows

```css
/* Still works if dark enough background */
box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
```

### 4. Elevation Through Color

Use slightly lighter background colors for elevated elements instead of shadows.

## Strokes with Shadows

Combine for definition:

```css
/* Subtle stroke + shadow */
border: 1px solid rgba(0, 0, 0, 0.05);
box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);
```

**Stroke opacity:** 5-20% for subtle definition

---

# Gradients

## Gradient Types

### Linear

Straight transition between colors:

```css
background: linear-gradient(180deg, #667eea 0%, #764ba2 100%);
```

**Use for:** Buttons, backgrounds, overlays

### Radial

Circular transition from center:

```css
background: radial-gradient(circle at center, #667eea 0%, #764ba2 100%);
```

**Use for:** Spotlights, glows, focal points

### Angular/Conic

Colors around a center point:

```css
background: conic-gradient(from 0deg, #667eea, #764ba2, #667eea);
```

**Use for:** Pie charts, color wheels, abstract effects

### Mesh

Multi-color, complex gradients (require tools/plugins to create).

**Use for:** Abstract backgrounds, hero sections

## Gradient Best Practices

### Choose Adjacent Hues

Colors next to each other on color wheel blend smoothly:

```
✅ Blue → Purple (adjacent)
✅ Orange → Yellow (adjacent)
❌ Red → Green (opposite, muddy)
```

### Add Middle Stops

For smoother multi-color gradients:

```css
/* Without middle stop - can look harsh */
background: linear-gradient(90deg, #ff0000, #0000ff);

/* With middle stop - smoother */
background: linear-gradient(90deg, #ff0000, #ff00ff, #0000ff);
```

### Adjust Stop Positions

Move stops toward one end for asymmetric blends:

```css
/* Stops clustered at end */
background: linear-gradient(90deg,
  #667eea 0%,
  #764ba2 70%,
  #9b59b6 90%,
  #c39bd3 100%
);
```

### Add Noise/Texture

Flat gradients can look "banded." Add subtle noise:
- Overlay grainy texture at 2-5% opacity
- Creates depth and visual interest

## Gradient Uses

### Button Gradients

```css
/* Subtle top-to-bottom */
background: linear-gradient(180deg, #5a67d8 0%, #4c51bf 100%);
```

### Background Overlays

```css
/* Fade to transparent for image overlays */
background: linear-gradient(180deg,
  rgba(0,0,0,0) 0%,
  rgba(0,0,0,0.8) 100%
);
```

### Hero Backgrounds

```css
/* Radial spotlight effect */
background: radial-gradient(
  ellipse at top center,
  rgba(102, 126, 234, 0.4) 0%,
  transparent 70%
);
```

### Light Source Effect

Layer blurred gradient for "godly rays":

```css
/* Large blurred ellipse */
.glow {
  background: radial-gradient(ellipse, #667eea 0%, transparent 70%);
  filter: blur(40px);
  opacity: 0.6;
}
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Too many colors | Max 3-4 colors per gradient |
| Opposite hue colors | Use adjacent hues |
| Overusing gradients | Use sparingly for emphasis |
| Harsh transitions | Add middle color stops |
| Banding artifacts | Add subtle noise texture |
| Inconsistent directions | Keep gradient angles consistent |

## Tools

- **Beautiful Shadows:** Figma plugin for layered shadows
- **Mesh gradients:** meshgradient.in, grainy-gradients.vercel.app
- **CSS generators:** cssgradient.io, shadows.brumm.af
