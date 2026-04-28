import StyleDictionary from 'style-dictionary';

// ---------- Type predicates ------------------------------------------------

const isColor    = (t) => t.type === 'color';
const isShadow   = (t) => t.type === 'boxShadow';
const isFontSize = (t) => t.type === 'fontSize';
const isSpacing  = (t) => t.type === 'spacing';
const isRadius   = (t) => t.type === 'borderRadius';

// ---------- Colour conversions --------------------------------------------

const hexToUIColor = (hex) => {
  const h = hex.replace('#', '');
  const r = parseInt(h.substring(0, 2), 16) / 255;
  const g = parseInt(h.substring(2, 4), 16) / 255;
  const b = parseInt(h.substring(4, 6), 16) / 255;
  return { r: r.toFixed(4), g: g.toFixed(4), b: b.toFixed(4), a: '1.0000' };
};

const rgbaToUIColor = (rgba) => {
  const m = rgba.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)/);
  if (!m) return null;
  return {
    r: (parseInt(m[1]) / 255).toFixed(4),
    g: (parseInt(m[2]) / 255).toFixed(4),
    b: (parseInt(m[3]) / 255).toFixed(4),
    a: (m[4] !== undefined ? parseFloat(m[4]) : 1).toFixed(4),
  };
};

const colorToSwiftUI = (value) => {
  if (typeof value !== 'string') return null;
  if (value.startsWith('#')) {
    const c = hexToUIColor(value);
    return `Color(red: ${c.r}, green: ${c.g}, blue: ${c.b}, opacity: ${c.a})`;
  }
  if (value.startsWith('rgb')) {
    const c = rgbaToUIColor(value);
    if (!c) return null;
    return `Color(red: ${c.r}, green: ${c.g}, blue: ${c.b}, opacity: ${c.a})`;
  }
  return null;
};

// ---------- Identifier helpers --------------------------------------------

// Swift identifiers cannot start with a digit. We prefix any name segment
// whose first char is a digit with `r` (radius / spacing have these).
const safeIdent = (segments) =>
  segments
    .map((s) => (/^[0-9]/.test(s) ? `r${s}` : s))
    .join('_')
    .replace(/[^A-Za-z0-9_]/g, '_');

// ---------- Lookup helpers (for the semantic emitter) ---------------------

// Build a quick lookup of every base colour token by dotted path so we can
// resolve aliases like "color.gray.900" to a concrete `Color(...)` literal.
const buildBaseColorMap = (allTokens) => {
  const map = new Map();
  for (const t of allTokens) {
    if (!isColor(t)) continue;
    const key = t.path.join('.');
    const literal = colorToSwiftUI(t.value);
    if (literal) map.set(key, literal);
  }
  return map;
};

// Resolve a token's `original.value` (a `{color.gray.900}` reference or a
// hex/rgba literal) to a Swift `Color(...)` expression. Returns null if
// unresolvable.
const resolveSemanticColour = (token, baseMap) => {
  // If it's already a literal value, convert directly.
  const direct = colorToSwiftUI(token.value);
  if (direct) return direct;

  // Style Dictionary stores the original `{...}` string in `original.value`.
  const orig = token.original && token.original.value;
  if (typeof orig === 'string') {
    const m = orig.match(/^\{([^}]+)\}$/);
    if (m) {
      const literal = baseMap.get(m[1]);
      if (literal) return literal;
    }
    const lit = colorToSwiftUI(orig);
    if (lit) return lit;
  }
  return null;
};

// ---------- Custom formats: SwiftUI ---------------------------------------

StyleDictionary.registerFormat({
  name: 'swiftui/color-extension',
  format: ({ dictionary }) => {
    const lines = [
      '// AUTO-GENERATED. Do not edit by hand.',
      '// Generated from design-system/tokens/ via Style Dictionary.',
      '',
      'import SwiftUI',
      '',
      'public enum DSColor {',
    ];
    dictionary.allTokens
      .filter(isColor)
      .filter((t) => t.path[0] === 'color')
      .forEach((t) => {
        const swift = colorToSwiftUI(t.value);
        if (!swift) return;
        const name = safeIdent(t.path);
        lines.push(`    public static let ${name} = ${swift}`);
      });
    lines.push('}', '');
    return lines.join('\n');
  },
});

StyleDictionary.registerFormat({
  name: 'swiftui/spacing-extension',
  format: ({ dictionary }) => {
    const lines = [
      '// AUTO-GENERATED. Do not edit by hand.',
      '',
      'import CoreGraphics',
      '',
      'public enum DSSpacing {',
    ];
    dictionary.allTokens.filter(isSpacing).forEach((t) => {
      const name = safeIdent(t.path);
      lines.push(`    public static let ${name}: CGFloat = ${t.value}`);
    });
    lines.push('}', '', 'public enum DSRadius {');
    dictionary.allTokens.filter(isRadius).forEach((t) => {
      // path is e.g. ['radius', '2xl'] → safeIdent → 'radius_r2xl'.
      // Strip the leading 'radius_' segment for cleaner consumer code.
      const tail = t.path.slice(1);
      const name = safeIdent(tail);
      lines.push(`    public static let ${name}: CGFloat = ${t.value}`);
    });
    lines.push('}', '', 'public enum DSFontSize {');
    dictionary.allTokens.filter(isFontSize).forEach((t) => {
      const tail = t.path.slice(1); // drop leading 'font'
      const name = safeIdent(tail);
      lines.push(`    public static let ${name}: CGFloat = ${t.value}`);
    });
    lines.push('}', '');
    return lines.join('\n');
  },
});

// One Color per semantic role, resolving light/dark to a UIColor with
// `UITraitCollection`-driven dynamic provider so SwiftUI swaps automatically
// when the system colour scheme changes.
StyleDictionary.registerFormat({
  name: 'swiftui/semantic-extension',
  format: ({ dictionary }) => {
    const baseMap = buildBaseColorMap(dictionary.allTokens);

    // Group semantic tokens by role and gather light/dark values.
    const roles = new Map(); // key: "text.primary" → { light, dark }
    for (const t of dictionary.allTokens) {
      if (!isColor(t)) continue;
      if (t.path[0] !== 'semantic') continue;
      const scheme = t.path[1]; // "light" | "dark"
      const role = t.path.slice(2).join('.'); // e.g. "text.primary"
      if (!role) continue;
      if (!roles.has(role)) roles.set(role, {});
      const swift = resolveSemanticColour(t, baseMap);
      if (swift) roles.get(role)[scheme] = swift;
    }

    const groups = {}; // first segment → array of [name, light, dark]
    for (const [role, pair] of roles.entries()) {
      if (!pair.light || !pair.dark) continue;
      const segments = role.split('.');
      const top = segments[0];
      const tail = segments.slice(1).join('_');
      const name = safeIdent(segments.slice(1)); // e.g. ['primary'] → 'primary'
      groups[top] = groups[top] || [];
      groups[top].push({ name: name || 'value', light: pair.light, dark: pair.dark });
    }

    const lines = [
      '// AUTO-GENERATED. Do not edit by hand.',
      '// Resolves semantic light/dark colour pairs to Color values that',
      '// switch automatically with the system colour scheme.',
      '',
      'import SwiftUI',
      '#if canImport(UIKit)',
      'import UIKit',
      '#endif',
      '',
      '#if canImport(UIKit)',
      'private func dsDynamic(light: Color, dark: Color) -> Color {',
      '    Color(UIColor { traits in',
      '        switch traits.userInterfaceStyle {',
      '        case .dark:  return UIColor(dark)',
      '        default:     return UIColor(light)',
      '        }',
      '    })',
      '}',
      '#else',
      'private func dsDynamic(light: Color, dark: Color) -> Color { light }',
      '#endif',
      '',
      'public enum DSSemantic {',
    ];
    for (const [top, items] of Object.entries(groups)) {
      lines.push(`    public enum ${top.charAt(0).toUpperCase() + top.slice(1)} {`);
      items.forEach((it) => {
        lines.push(
          `        public static let ${it.name}: Color = dsDynamic(light: ${it.light}, dark: ${it.dark})`
        );
      });
      lines.push('    }');
    }
    lines.push('}', '');
    return lines.join('\n');
  },
});

// ---------- Custom formats: CSS semantic ----------------------------------

// Emit the semantic palette as CSS custom properties under :root for light
// mode and override under @media (prefers-color-scheme: dark).
StyleDictionary.registerFormat({
  name: 'css/semantic-variables',
  format: ({ dictionary }) => {
    const baseMap = new Map();
    for (const t of dictionary.allTokens) {
      if (!isColor(t)) continue;
      const key = t.path.join('.');
      // Build a CSS-friendly representation in addition to the SwiftUI map.
      let css = null;
      if (typeof t.value === 'string') {
        css = t.value.startsWith('#') || t.value.startsWith('rgb') ? t.value : null;
      }
      if (css) baseMap.set(key, css);
    }

    const resolveCSS = (token) => {
      if (typeof token.value === 'string') {
        if (token.value.startsWith('#') || token.value.startsWith('rgb')) {
          return token.value;
        }
      }
      const orig = token.original && token.original.value;
      if (typeof orig === 'string') {
        const m = orig.match(/^\{([^}]+)\}$/);
        if (m) return baseMap.get(m[1]);
        if (orig.startsWith('#') || orig.startsWith('rgb')) return orig;
      }
      return null;
    };

    const lightLines = [];
    const darkLines = [];
    for (const t of dictionary.allTokens) {
      if (!isColor(t)) continue;
      if (t.path[0] !== 'semantic') continue;
      const scheme = t.path[1];
      const role = t.path.slice(2).join('-'); // text-primary, bg-surface, …
      const css = resolveCSS(t);
      if (!css) continue;
      const decl = `  --${role}: ${css};`;
      if (scheme === 'light') lightLines.push(decl);
      else if (scheme === 'dark') darkLines.push(decl);
    }
    return [
      '/* AUTO-GENERATED. Do not edit by hand. */',
      ':root {',
      ...lightLines,
      '}',
      '',
      '@media (prefers-color-scheme: dark) {',
      '  :root {',
      ...darkLines.map((l) => '  ' + l),
      '  }',
      '}',
      '',
    ].join('\n');
  },
});

// ---------- Custom transform ----------------------------------------------

StyleDictionary.registerTransform({
  name: 'size/px',
  type: 'value',
  filter: (t) => isSpacing(t) || isRadius(t) || isFontSize(t),
  transform: (t) => `${t.value}px`,
});

// ---------- Custom CSS format ---------------------------------------------
// Style Dictionary's bundled `css/variables` doesn't reliably re-render
// transformed values for size tokens in our setup, so we emit a flat
// `:root { --name: value; }` block ourselves and explicitly suffix `px`
// onto spacing/radius/fontSize.

StyleDictionary.registerFormat({
  name: 'css/variables-with-units',
  format: ({ dictionary }) => {
    const lines = ['/* AUTO-GENERATED. Do not edit by hand. */', ':root {'];
    for (const t of dictionary.allTokens) {
      const name = t.path
        .map((s) => s.replace(/\./g, '_'))
        .join('-');
      let value = t.value;
      if (typeof value === 'string') {
        if ((isSpacing(t) || isRadius(t) || isFontSize(t)) && !value.endsWith('px')) {
          value = `${value}px`;
        }
      }
      lines.push(`  --${name}: ${value};`);
    }
    lines.push('}', '');
    return lines.join('\n');
  },
});

// ---------- Build configuration -------------------------------------------

export default {
  source: ['tokens/**/*.json'],
  log: { verbosity: 'verbose' },
  platforms: {
    css: {
      transforms: ['attribute/cti', 'name/kebab', 'color/css'],
      buildPath: 'build/css/',
      files: [
        {
          destination: 'tokens.css',
          format: 'css/variables-with-units',
        },
        {
          destination: 'tokens-semantic.css',
          format: 'css/semantic-variables',
        },
      ],
    },
    js: {
      transformGroup: 'js',
      buildPath: 'build/js/',
      files: [
        { destination: 'tokens.js', format: 'javascript/esm' },
        { destination: 'tokens.d.ts', format: 'typescript/es6-declarations' },
      ],
    },
    json: {
      transformGroup: 'js',
      buildPath: 'build/json/',
      files: [{ destination: 'tokens.json', format: 'json/flat' }],
    },
    'ios-swiftui': {
      transforms: ['attribute/cti', 'name/camel'],
      buildPath: 'build/ios/',
      files: [
        { destination: 'DSColor.swift',    format: 'swiftui/color-extension' },
        { destination: 'DSMetrics.swift',  format: 'swiftui/spacing-extension' },
        { destination: 'DSSemantic.swift', format: 'swiftui/semantic-extension' },
      ],
    },
    android: {
      transformGroup: 'android',
      buildPath: 'build/android/',
      files: [
        { destination: 'colors.xml',     format: 'android/colors' },
        { destination: 'dimens.xml',     format: 'android/dimens' },
        { destination: 'font_dimens.xml',format: 'android/fontDimens' },
      ],
    },
  },
};
