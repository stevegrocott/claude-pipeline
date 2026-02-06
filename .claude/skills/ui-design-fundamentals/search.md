# Search

## Core Principles

Good search:
- Easy to find
- Fast to use
- Helpful with suggestions
- Graceful with no results

## Search Bar Anatomy

```
┌─────────────────────────────────────────┐
│ 🔍 │ Search products...            │ ✕ │
└─────────────────────────────────────────┘
  ↑              ↑                     ↑
Icon        Placeholder           Clear button
(optional)   (helpful)           (when has value)
```

### Components

| Element | Purpose | Required |
|---------|---------|----------|
| Input field | Text entry | Yes |
| Search icon | Visual indicator | Recommended |
| Placeholder | Hint/example | Recommended |
| Clear button | Reset search | When filled |
| Submit button | Trigger search | Optional |

## Placement

### Header Search

```
┌─────────────────────────────────────────────────────┐
│ [Logo]  Nav  Nav  Nav    [🔍 Search...    ]  [CTA] │
└─────────────────────────────────────────────────────┘
```

- Prominent position
- Always accessible
- Good for search-heavy apps

### Icon Toggle

```
Collapsed:                    Expanded:
┌─────────────────────┐      ┌─────────────────────────┐
│ [Logo]  Nav  🔍     │  →   │ [🔍 Search...        ✕] │
└─────────────────────┘      └─────────────────────────┘
```

- Saves space
- Click icon to expand
- Click X or blur to collapse

### Page Search

```
┌─────────────────────────────────────────┐
│           Welcome Back, User            │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │ 🔍 Search for anything...         │  │
│  └───────────────────────────────────┘  │
│                                         │
└─────────────────────────────────────────┘
```

- Prominent on dashboard/home
- Large and inviting
- Clear purpose

### Command Palette (⌘K)

```
┌─────────────────────────────────────────┐
│ 🔍 Type a command or search...          │
├─────────────────────────────────────────┤
│ Recent                                  │
│   📄 Dashboard                          │
│   📄 Settings                           │
│                                         │
│ Suggestions                             │
│   → Create new project                  │
│   → Invite team member                  │
└─────────────────────────────────────────┘
```

- Global search
- Keyboard shortcut (⌘K or Ctrl+K)
- Power user feature
- Commands + content

## Input Styling

### Dimensions

| Context | Height | Width |
|---------|--------|-------|
| Header | 40-44px | 200-400px |
| Page hero | 48-56px | 400-600px |
| Mobile | 44-48px | Full width |

### Border Styles

```css
/* Subtle */
.search {
  background: #f3f4f6;
  border: none;
  border-radius: 8px;
}

/* Outlined */
.search {
  background: white;
  border: 1px solid #e5e7eb;
  border-radius: 8px;
}

/* Pill */
.search {
  background: white;
  border: 1px solid #e5e7eb;
  border-radius: 9999px;
}
```

### States

| State | Visual |
|-------|--------|
| Default | Normal border |
| Focus | Primary border, outline ring |
| Filled | Clear button visible |
| Loading | Spinner |
| Error | Red border (rare for search) |

## Placeholder Text

### Guidelines

- Describe what can be searched
- Show example queries
- Keep concise

### Examples

| Generic | Better |
|---------|--------|
| "Search" | "Search products..." |
| "Type here" | "Search by name or ID" |
| "Enter query" | "Try 'blue sneakers'" |

## Recent Searches

```
┌─────────────────────────────────────────┐
│ 🔍 │                               │   │
├─────────────────────────────────────────┤
│ Recent searches              Clear all  │
│ ┌─────────────────────────────────────┐ │
│ │ 🕐 blue sneakers               ✕   │ │
│ │ 🕐 running shoes               ✕   │ │
│ │ 🕐 nike air max                ✕   │ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

### Features

- Show on focus (empty input)
- Individual delete (X)
- Clear all option
- Limit to 5-10 items
- Persist across sessions

## Autocomplete

```
┌─────────────────────────────────────────┐
│ 🔍 │ sneak                         │   │
├─────────────────────────────────────────┤
│ sneakers                                │
│ sneaker cleaning kit                    │
│ sneakers for men                        │
│ sneakers white                          │
└─────────────────────────────────────────┘
```

### Guidelines

- Start after 2-3 characters
- Debounce input (300ms)
- Highlight matching text
- Keyboard navigation (↑↓)
- Enter to select
- Limit suggestions (5-10)

### Rich Suggestions

```
┌─────────────────────────────────────────┐
│ 🔍 │ nike                           │   │
├─────────────────────────────────────────┤
│ Products                                │
│   👟 Nike Air Max 90           $129    │
│   👟 Nike Dunk Low             $110    │
│                                         │
│ Categories                              │
│   📁 Nike Running Shoes                 │
│   📁 Nike Basketball                    │
│                                         │
│ [See all results for "nike"]            │
└─────────────────────────────────────────┘
```

- Group by type
- Show images/icons
- Include metadata (price, count)
- Link to full results

## No Results

### Bad

```
┌─────────────────────────────────────────┐
│           No results found              │
└─────────────────────────────────────────┘
```

### Good

```
┌─────────────────────────────────────────┐
│                                         │
│            🔍                           │
│                                         │
│   No results for "xyzabc"               │
│                                         │
│   Suggestions:                          │
│   • Check your spelling                 │
│   • Try broader terms                   │
│   • Use fewer keywords                  │
│                                         │
│   Popular searches:                     │
│   sneakers • jackets • accessories      │
│                                         │
└─────────────────────────────────────────┘
```

### Include

- Acknowledge the search term
- Helpful suggestions
- Popular/related searches
- Alternative actions
- Contact support link (if appropriate)

## Search Results

### Result Item

```
┌─────────────────────────────────────────┐
│ 🖼️ │ Product Title                      │
│    │ Brief description with keyword...  │
│    │ $99.00 • ⭐ 4.5 (120 reviews)      │
└─────────────────────────────────────────┘
```

### Result Page Elements

- Result count: "124 results for 'sneakers'"
- Sort options: Relevance, Price, Date
- Filters: Category, Price range, etc.
- Pagination or infinite scroll
- Clear search/reset

## Mobile Considerations

### Full-Screen Search

```
┌─────────────────────────────────────────┐
│ ← │ 🔍 Search...                 │ Cancel│
├─────────────────────────────────────────┤
│                                         │
│ Recent searches                         │
│ • Previous query 1                      │
│ • Previous query 2                      │
│                                         │
│ Trending                                │
│ • Popular term 1                        │
│ • Popular term 2                        │
│                                         │
└─────────────────────────────────────────┘
```

- Full-screen overlay
- Large input area
- Easy to dismiss
- Keyboard auto-opens

### Input Optimizations

```html
<input
  type="search"
  inputmode="search"
  autocomplete="off"
  autocorrect="off"
  autocapitalize="off"
/>
```

- Search keyboard on mobile
- Disable autocorrect (for names, IDs)
- Submit on keyboard "Search" button

## Accessibility

### ARIA

```html
<div role="search">
  <label for="search" class="sr-only">Search</label>
  <input
    id="search"
    type="search"
    aria-label="Search products"
    aria-autocomplete="list"
    aria-controls="suggestions"
  />
  <ul id="suggestions" role="listbox">
    <li role="option">Suggestion 1</li>
  </ul>
</div>
```

### Keyboard

- Tab to focus
- Type to search
- ↑↓ navigate suggestions
- Enter to select/search
- Escape to close suggestions

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Hidden search | Make prominent and accessible |
| No placeholder | Add helpful hint |
| Generic "No results" | Provide suggestions and alternatives |
| No recent searches | Save and display history |
| Slow suggestions | Debounce and optimize API |
| Can't clear search | Add clear button |
| No keyboard nav | Implement arrow key navigation |
