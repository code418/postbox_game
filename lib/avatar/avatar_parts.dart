// Postie avatar parts — port of design-system/Character Creator/parts.js.
//
// All parts share viewBox 0 0 200 200; head centred on (100, 88), chin ≈ y=132.
// SVG paths are embedded as strings and assembled at render time.

class NamedItem {
  final String id;
  final String name;
  const NamedItem(this.id, this.name);
}

class ColorOption extends NamedItem {
  final String fill;
  final String? shade;
  const ColorOption(super.id, super.name, this.fill, [this.shade]);
}

class HeadShape extends NamedItem {
  final String face;
  final String earL;
  final String earR;
  const HeadShape(super.id, super.name, this.face, this.earL, this.earR);
}

class HairStyle extends NamedItem {
  final String? path;
  const HairStyle(super.id, super.name, this.path);
}

/// Eyes are a chunk of inner-svg (children of the root). Drawn around
/// (82, 90) and (118, 90).
class EyesOption extends NamedItem {
  final String svg;
  const EyesOption(super.id, super.name, this.svg);
}

class NoseOption extends NamedItem {
  final String path;
  final bool filled; // round/snub get a soft shade fill
  const NoseOption(super.id, super.name, this.path, {this.filled = false});
}

class FacialOption extends NamedItem {
  final String? path;
  final bool stubble;
  const FacialOption(super.id, super.name, {this.path, this.stubble = false});
}

class HatOption extends NamedItem {
  final String? svg;
  const HatOption(super.id, super.name, this.svg);
}

class GlassesOption extends NamedItem {
  final String? svg;
  const GlassesOption(super.id, super.name, this.svg);
}

const List<ColorOption> avatarSkin = [
  ColorOption('fair', 'Fair', '#ffd9c4', '#e8b79a'),
  ColorOption('peach', 'Peach', '#ffc9a8', '#e8a582'),
  ColorOption('tan', 'Tan', '#d9a178', '#b8825c'),
  ColorOption('olive', 'Olive', '#c89070', '#a47050'),
  ColorOption('brown', 'Brown', '#9a6645', '#764a30'),
  ColorOption('deep', 'Deep', '#5e3a22', '#3e2413'),
  ColorOption('mint', 'Mint', '#b8e6c9', '#8dc9a3'),
  ColorOption('lilac', 'Lilac', '#d4b8e8', '#b094cc'),
];

const List<ColorOption> avatarHairColors = [
  ColorOption('black', 'Black', '#1a1a1a'),
  ColorOption('brown', 'Brown', '#6b4226'),
  ColorOption('chestnut', 'Chestnut', '#8b5a2b'),
  ColorOption('blond', 'Blond', '#e8c174'),
  ColorOption('ginger', 'Ginger', '#c86428'),
  ColorOption('grey', 'Grey', '#a8a8a8'),
  ColorOption('white', 'White', '#f0ece4'),
  ColorOption('blue', 'Blue', '#3f6fb8'),
];

const List<ColorOption> avatarBackgrounds = [
  ColorOption('red', 'Pillar Box', '#C8102E'),
  ColorOption('navy', 'Royal Navy', '#0A1931'),
  ColorOption('gold', 'Gold', '#FFB400'),
  ColorOption('parch', 'Parchment', '#FFF8F0'),
  ColorOption('mint', 'Sorting', '#a8d4bc'),
  ColorOption('dusk', 'Dusk', '#6b7ba8'),
  ColorOption('stamp', 'Stamp Blue', '#005EB8'),
  ColorOption('hedge', 'Hedgerow', '#4a7848'),
];

const List<HeadShape> avatarHeads = [
  HeadShape(
    'oval', 'Oval',
    'M 100 46 C 78 46 62 62 62 88 C 62 112 76 132 100 132 C 124 132 138 112 138 88 C 138 62 122 46 100 46 Z',
    'M 64 88 Q 56 90 58 100 Q 60 110 66 108',
    'M 136 88 Q 144 90 142 100 Q 140 110 134 108',
  ),
  HeadShape(
    'round', 'Round',
    'M 100 46 C 76 46 58 64 58 90 C 58 114 76 134 100 134 C 124 134 142 114 142 90 C 142 64 124 46 100 46 Z',
    'M 60 92 Q 51 94 54 104 Q 57 114 64 112',
    'M 140 92 Q 149 94 146 104 Q 143 114 136 112',
  ),
  HeadShape(
    'square', 'Square',
    'M 100 47 C 80 47 64 58 63 80 L 64 110 C 65 124 80 134 100 134 C 120 134 135 124 136 110 L 137 80 C 136 58 120 47 100 47 Z',
    'M 65 90 Q 56 92 58 102 Q 60 112 67 110',
    'M 135 90 Q 144 92 142 102 Q 140 112 133 110',
  ),
  HeadShape(
    'long', 'Long',
    'M 100 42 C 80 42 66 58 66 84 C 66 116 78 138 100 138 C 122 138 134 116 134 84 C 134 58 120 42 100 42 Z',
    'M 68 90 Q 60 92 62 102 Q 64 112 70 110',
    'M 132 90 Q 140 92 138 102 Q 136 112 130 110',
  ),
  HeadShape(
    'heart', 'Heart',
    'M 100 46 C 78 46 62 60 62 82 C 62 108 78 134 100 134 C 122 134 138 108 138 82 C 138 60 122 46 100 46 Z',
    'M 64 86 Q 55 88 57 98 Q 59 108 65 106',
    'M 136 86 Q 145 88 143 98 Q 141 108 135 106',
  ),
  HeadShape(
    'chubby', 'Chubby',
    'M 100 50 C 74 50 56 64 56 92 C 56 116 74 136 100 136 C 126 136 144 116 144 92 C 144 64 126 50 100 50 Z',
    'M 58 94 Q 48 96 50 106 Q 52 118 60 116',
    'M 142 94 Q 152 96 150 106 Q 148 118 140 116',
  ),
  HeadShape(
    'narrow', 'Narrow',
    'M 100 46 C 82 46 70 60 70 86 C 70 112 82 132 100 132 C 118 132 130 112 130 86 C 130 60 118 46 100 46 Z',
    'M 72 88 Q 64 90 66 100 Q 68 110 74 108',
    'M 128 88 Q 136 90 134 100 Q 132 110 126 108',
  ),
  HeadShape(
    'pointed', 'Pointed',
    'M 100 46 C 78 46 62 62 62 86 C 62 106 74 122 90 130 L 100 138 L 110 130 C 126 122 138 106 138 86 C 138 62 122 46 100 46 Z',
    'M 64 88 Q 55 90 57 100 Q 59 110 66 108',
    'M 136 88 Q 145 90 143 100 Q 141 110 134 108',
  ),
];

const List<HairStyle> avatarHair = [
  HairStyle('bald', 'Bald', null),
  HairStyle('crop', 'Short Crop',
      'M 66 66 C 64 56 72 46 84 44 C 90 40 110 40 116 44 C 128 46 136 56 134 66 C 134 70 132 72 128 70 C 120 66 112 62 100 62 C 88 62 80 66 72 70 C 68 72 66 70 66 66 Z'),
  HairStyle('side', 'Side Parting',
      'M 64 72 C 62 58 72 44 90 44 C 102 38 124 40 132 52 C 138 58 138 68 134 74 C 132 76 130 74 128 72 C 122 64 110 60 100 62 C 92 62 86 66 80 72 C 76 76 76 82 74 86 C 72 78 66 76 64 72 Z'),
  HairStyle('quiff', 'Quiff',
      'M 68 72 C 60 62 68 44 84 42 C 90 32 112 34 118 44 C 122 40 132 42 134 54 C 138 60 138 72 132 74 C 128 70 120 66 112 64 C 120 58 118 48 110 48 C 104 48 100 54 100 60 C 98 56 92 56 88 60 C 82 64 76 70 72 76 C 70 74 68 74 68 72 Z'),
  HairStyle('curly', 'Curly',
      'M 60 76 C 54 66 58 48 74 42 C 80 34 98 34 104 40 C 112 34 128 38 132 50 C 142 54 144 70 138 80 C 136 84 132 82 130 78 C 132 72 128 66 122 66 C 124 72 120 76 116 72 C 118 66 114 60 108 62 C 110 56 104 54 100 58 C 98 54 92 54 90 58 C 88 54 82 56 82 62 C 78 60 74 64 76 70 C 72 68 66 72 68 78 C 68 82 64 82 62 80 C 60 80 60 78 60 76 Z'),
  HairStyle('long', 'Long',
      'M 60 82 C 54 64 66 44 86 42 C 94 36 112 38 120 46 C 134 48 142 64 138 80 C 138 98 136 118 138 128 C 132 122 130 112 130 102 C 128 94 124 88 118 86 C 112 74 102 70 92 74 C 84 80 78 90 74 100 C 72 114 70 126 64 132 C 62 118 64 102 64 90 C 62 86 60 84 60 82 Z'),
  HairStyle('mohawk', 'Mohawk',
      'M 94 30 L 98 42 L 94 44 L 92 50 L 96 52 L 92 58 L 98 60 L 94 66 L 100 68 L 106 66 L 102 60 L 108 58 L 104 52 L 108 50 L 106 44 L 102 42 L 106 30 Z'),
  HairStyle('bun', 'Top Bun',
      'M 66 70 C 62 58 70 46 84 44 C 88 34 96 30 100 32 C 100 24 108 22 110 28 C 116 26 120 32 116 38 C 120 42 120 48 114 48 C 124 50 134 58 134 70 C 134 74 132 74 128 72 C 118 66 110 62 100 62 C 88 62 80 66 72 72 C 68 72 66 72 66 70 Z'),
];

const List<EyesOption> avatarEyes = [
  EyesOption('dots', 'Dots',
      '<circle cx="82" cy="90" r="2.2" fill="#1a1a1a"/><circle cx="118" cy="90" r="2.2" fill="#1a1a1a"/>'),
  EyesOption('round', 'Round',
      '<ellipse cx="82" cy="90" rx="5" ry="5.5" fill="#fff" stroke="#1a1a1a" stroke-width="1.6"/><ellipse cx="118" cy="90" rx="5" ry="5.5" fill="#fff" stroke="#1a1a1a" stroke-width="1.6"/><circle cx="82.8" cy="91" r="2" fill="#1a1a1a"/><circle cx="118.8" cy="91" r="2" fill="#1a1a1a"/>'),
  EyesOption('happy', 'Happy',
      '<path d="M 77 92 Q 82 86 87 92" fill="none" stroke="#1a1a1a" stroke-width="1.8" stroke-linecap="round"/><path d="M 113 92 Q 118 86 123 92" fill="none" stroke="#1a1a1a" stroke-width="1.8" stroke-linecap="round"/>'),
  EyesOption('sleepy', 'Sleepy',
      '<path d="M 77 90 Q 82 94 87 90" fill="none" stroke="#1a1a1a" stroke-width="1.8" stroke-linecap="round"/><path d="M 113 90 Q 118 94 123 90" fill="none" stroke="#1a1a1a" stroke-width="1.8" stroke-linecap="round"/>'),
  EyesOption('wide', 'Wide',
      '<ellipse cx="82" cy="90" rx="6" ry="7" fill="#fff" stroke="#1a1a1a" stroke-width="1.6"/><ellipse cx="118" cy="90" rx="6" ry="7" fill="#fff" stroke="#1a1a1a" stroke-width="1.6"/><circle cx="83" cy="91" r="2.4" fill="#1a1a1a"/><circle cx="119" cy="91" r="2.4" fill="#1a1a1a"/><circle cx="83.6" cy="90.2" r="0.8" fill="#fff"/><circle cx="119.6" cy="90.2" r="0.8" fill="#fff"/>'),
  EyesOption('wink', 'Wink',
      '<ellipse cx="82" cy="90" rx="5" ry="5.5" fill="#fff" stroke="#1a1a1a" stroke-width="1.6"/><circle cx="82.8" cy="91" r="2" fill="#1a1a1a"/><path d="M 113 91 Q 118 87 123 91" fill="none" stroke="#1a1a1a" stroke-width="1.8" stroke-linecap="round"/>'),
  EyesOption('side', 'Looking Aside',
      '<ellipse cx="82" cy="90" rx="5" ry="5.5" fill="#fff" stroke="#1a1a1a" stroke-width="1.6"/><ellipse cx="118" cy="90" rx="5" ry="5.5" fill="#fff" stroke="#1a1a1a" stroke-width="1.6"/><circle cx="84.5" cy="91" r="2" fill="#1a1a1a"/><circle cx="120.5" cy="91" r="2" fill="#1a1a1a"/>'),
  EyesOption('stern', 'Stern',
      '<path d="M 76 88 Q 82 87 88 88" fill="none" stroke="#1a1a1a" stroke-width="2" stroke-linecap="round"/><path d="M 112 88 Q 118 87 124 88" fill="none" stroke="#1a1a1a" stroke-width="2" stroke-linecap="round"/><circle cx="82" cy="91" r="1.8" fill="#1a1a1a"/><circle cx="118" cy="91" r="1.8" fill="#1a1a1a"/>'),
];

const List<NoseOption> avatarNoses = [
  NoseOption('button', 'Button', 'M 98 104 Q 100 108 102 104'),
  NoseOption('long', 'Long', 'M 97 96 Q 96 106 100 110 Q 104 110 103 104'),
  NoseOption('wide', 'Wide', 'M 94 104 Q 98 110 106 110 Q 108 108 108 104'),
  NoseOption('pointy', 'Pointy', 'M 98 98 L 96 108 Q 100 112 104 108 L 102 98'),
  NoseOption('hook', 'Hooked', 'M 98 96 Q 94 104 96 110 Q 100 112 104 108'),
  NoseOption('small', 'Small', 'M 99 106 Q 100 108 101 106'),
  NoseOption('round', 'Round',
      'M 96 104 Q 96 112 100 112 Q 104 112 104 104 Q 100 102 96 104 Z',
      filled: true),
  NoseOption('snub', 'Snub',
      'M 96 108 Q 100 112 104 108 Q 104 104 100 104 Q 96 104 96 108 Z',
      filled: true),
];

const List<FacialOption> avatarFacial = [
  FacialOption('none', 'Clean Shaven'),
  FacialOption('mustache', 'Moustache',
      path: 'M 86 116 Q 92 118 100 116 Q 108 118 114 116 Q 110 122 100 120 Q 90 122 86 116 Z'),
  FacialOption('handlebar', 'Handlebar',
      path: 'M 82 114 Q 88 120 100 118 Q 112 120 118 114 Q 116 124 108 122 Q 104 118 100 120 Q 96 118 92 122 Q 84 124 82 114 Z'),
  FacialOption('goatee', 'Goatee',
      path: 'M 94 122 Q 100 126 106 122 Q 108 130 100 132 Q 92 130 94 122 Z'),
  FacialOption('chinstrap', 'Chin Strap',
      path: 'M 68 106 Q 70 126 100 130 Q 130 126 132 106 Q 128 126 100 128 Q 72 126 68 106 Z'),
  FacialOption('fullbeard', 'Full Beard',
      path: 'M 66 100 Q 64 124 78 134 Q 90 138 100 138 Q 110 138 122 134 Q 136 124 134 100 Q 132 122 120 126 Q 112 120 100 122 Q 88 120 80 126 Q 68 122 66 100 Z'),
  FacialOption('stubble', 'Stubble', stubble: true),
  FacialOption('soulpatch', 'Soul Patch',
      path: 'M 98 124 Q 100 128 102 124 Q 102 130 100 130 Q 98 130 98 124 Z'),
];

const List<HatOption> avatarHats = [
  HatOption('none', 'No Hat', null),
  HatOption('postman', 'Postman Cap', '''
        <path d="M 58 66 Q 58 52 72 46 Q 100 38 128 46 Q 142 52 142 66 Z" fill="#0A1931" stroke="#1a1a1a" stroke-width="2" stroke-linejoin="round"/>
        <rect x="56" y="62" width="88" height="8" rx="2" fill="#0A1931" stroke="#1a1a1a" stroke-width="2"/>
        <rect x="56" y="62" width="88" height="3" fill="#C8102E"/>
        <circle cx="100" cy="52" r="4" fill="#FFB400" stroke="#1a1a1a" stroke-width="1.4"/>
        <path d="M 97 52 L 100 48 L 103 52 L 100 56 Z" fill="#0A1931"/>
      '''),
  HatOption('beanie', 'Beanie', '''
        <path d="M 60 64 Q 58 40 80 34 Q 100 28 120 34 Q 142 40 140 64 Z" fill="#C8102E" stroke="#1a1a1a" stroke-width="2" stroke-linejoin="round"/>
        <rect x="58" y="60" width="84" height="8" rx="2" fill="#C8102E" stroke="#1a1a1a" stroke-width="2"/>
        <circle cx="100" cy="28" r="5" fill="#FFB400" stroke="#1a1a1a" stroke-width="1.4"/>
      '''),
  HatOption('bowler', 'Bowler', '''
        <ellipse cx="100" cy="58" rx="42" ry="5" fill="#1a1a1a"/>
        <path d="M 70 58 Q 70 28 100 28 Q 130 28 130 58 Z" fill="#1a1a1a" stroke="#1a1a1a" stroke-width="2"/>
      '''),
  HatOption('flatcap', 'Flat Cap', '''
        <path d="M 60 62 Q 58 46 84 42 Q 120 38 138 54 L 148 62 Q 148 66 142 66 L 60 66 Z" fill="#6b4226" stroke="#1a1a1a" stroke-width="2" stroke-linejoin="round"/>
        <path d="M 60 66 Q 100 58 138 62" fill="none" stroke="#1a1a1a" stroke-width="1.4" opacity="0.6"/>
      '''),
  HatOption('helmet', 'Bike Helmet', '''
        <path d="M 58 66 Q 56 36 100 34 Q 144 36 142 66 Z" fill="#FFB400" stroke="#1a1a1a" stroke-width="2" stroke-linejoin="round"/>
        <path d="M 74 44 L 82 58" stroke="#1a1a1a" stroke-width="1.5" opacity="0.5"/>
        <path d="M 100 36 L 100 56" stroke="#1a1a1a" stroke-width="1.5" opacity="0.5"/>
        <path d="M 126 44 L 118 58" stroke="#1a1a1a" stroke-width="1.5" opacity="0.5"/>
        <rect x="56" y="62" width="88" height="6" rx="2" fill="#1a1a1a"/>
      '''),
  HatOption('crown', 'Crown', '''
        <path d="M 68 64 L 68 38 L 80 50 L 92 30 L 100 48 L 108 30 L 120 50 L 132 38 L 132 64 Z" fill="#FFB400" stroke="#1a1a1a" stroke-width="2" stroke-linejoin="round"/>
        <circle cx="80" cy="50" r="2" fill="#C8102E" stroke="#1a1a1a" stroke-width="1"/>
        <circle cx="100" cy="48" r="2" fill="#005EB8" stroke="#1a1a1a" stroke-width="1"/>
        <circle cx="120" cy="50" r="2" fill="#C8102E" stroke="#1a1a1a" stroke-width="1"/>
        <rect x="64" y="60" width="72" height="6" fill="#FFB400" stroke="#1a1a1a" stroke-width="1.6"/>
      '''),
  HatOption('tophat', 'Top Hat', '''
        <ellipse cx="100" cy="62" rx="44" ry="5" fill="#1a1a1a"/>
        <rect x="74" y="20" width="52" height="42" fill="#1a1a1a" stroke="#1a1a1a" stroke-width="2"/>
        <rect x="74" y="52" width="52" height="6" fill="#C8102E"/>
      '''),
];

const List<GlassesOption> avatarGlasses = [
  GlassesOption('none', 'None', null),
  GlassesOption('round', 'Round',
      '<circle cx="82" cy="90" r="8" fill="none" stroke="#1a1a1a" stroke-width="2"/><circle cx="118" cy="90" r="8" fill="none" stroke="#1a1a1a" stroke-width="2"/><path d="M 90 90 L 110 90" stroke="#1a1a1a" stroke-width="2"/>'),
  GlassesOption('square', 'Square',
      '<rect x="73" y="83" width="18" height="14" rx="2" fill="none" stroke="#1a1a1a" stroke-width="2"/><rect x="109" y="83" width="18" height="14" rx="2" fill="none" stroke="#1a1a1a" stroke-width="2"/><path d="M 91 90 L 109 90" stroke="#1a1a1a" stroke-width="2"/>'),
  GlassesOption('aviator', 'Aviator',
      '<path d="M 72 85 Q 72 98 82 98 Q 92 98 92 85 Z" fill="none" stroke="#1a1a1a" stroke-width="2"/><path d="M 108 85 Q 108 98 118 98 Q 128 98 128 85 Z" fill="none" stroke="#1a1a1a" stroke-width="2"/><path d="M 92 88 L 108 88" stroke="#1a1a1a" stroke-width="2"/>'),
  GlassesOption('halfmoon', 'Half-Moon',
      '<path d="M 73 90 Q 82 98 91 90" fill="none" stroke="#1a1a1a" stroke-width="2"/><path d="M 109 90 Q 118 98 127 90" fill="none" stroke="#1a1a1a" stroke-width="2"/><path d="M 73 90 L 91 90" stroke="#1a1a1a" stroke-width="2"/><path d="M 109 90 L 127 90" stroke="#1a1a1a" stroke-width="2"/><path d="M 91 90 L 109 90" stroke="#1a1a1a" stroke-width="2"/>'),
  GlassesOption('shades', 'Dark Shades',
      '<rect x="73" y="83" width="18" height="12" rx="3" fill="#1a1a1a"/><rect x="109" y="83" width="18" height="12" rx="3" fill="#1a1a1a"/><path d="M 91 89 L 109 89" stroke="#1a1a1a" stroke-width="2"/>'),
  GlassesOption('monocle', 'Monocle',
      '<circle cx="118" cy="90" r="9" fill="none" stroke="#1a1a1a" stroke-width="2"/><path d="M 127 94 Q 132 100 136 110" fill="none" stroke="#1a1a1a" stroke-width="1.5"/>'),
  GlassesOption('eyepatch', 'Eye Patch',
      '<path d="M 72 84 L 96 84 L 92 100 L 74 98 Z" fill="#1a1a1a" stroke="#1a1a1a" stroke-width="1.5" stroke-linejoin="round"/><path d="M 96 84 Q 110 78 128 82" fill="none" stroke="#1a1a1a" stroke-width="1.2"/>'),
];

/// Postman uniform — shoulders + collar + tie. Drawn behind the head.
const String avatarUniformSvg = '''
    <path d="M 30 200 Q 34 160 56 150 Q 76 144 100 146 Q 124 144 144 150 Q 166 160 170 200 L 170 210 L 30 210 Z" fill="#0A1931" stroke="#1a1a1a" stroke-width="2" stroke-linejoin="round"/>
    <path d="M 80 150 L 100 168 L 120 150" fill="#fff" stroke="#1a1a1a" stroke-width="1.8" stroke-linejoin="round"/>
    <path d="M 80 150 L 90 164 L 100 160 Z" fill="#fff" stroke="#1a1a1a" stroke-width="1.6" stroke-linejoin="round"/>
    <path d="M 120 150 L 110 164 L 100 160 Z" fill="#fff" stroke="#1a1a1a" stroke-width="1.6" stroke-linejoin="round"/>
    <path d="M 96 160 Q 100 164 104 160 L 106 168 Q 100 172 94 168 Z" fill="#C8102E" stroke="#1a1a1a" stroke-width="1.5" stroke-linejoin="round"/>
    <path d="M 94 168 L 92 202 Q 100 206 108 202 L 106 168" fill="#C8102E" stroke="#1a1a1a" stroke-width="1.5" stroke-linejoin="round"/>
    <circle cx="72" cy="168" r="1.6" fill="#FFB400"/>
''';

String avatarNeckSvg(String skinFill, String skinShade) => '''
    <path d="M 88 128 L 86 146 Q 100 152 114 146 L 112 128 Z" fill="$skinFill" stroke="#1a1a1a" stroke-width="2" stroke-linejoin="round"/>
    <path d="M 88 142 Q 100 148 112 142" fill="none" stroke="$skinShade" stroke-width="1.2" opacity="0.6"/>
''';

String avatarStubbleSvg(String color) {
  const positions = <List<num>>[
    [76, 116], [82, 118], [88, 120], [94, 122], [100, 124], [106, 122],
    [112, 120], [118, 118], [124, 116],
    [72, 110], [80, 114], [92, 118], [108, 118], [120, 114], [128, 110],
    [90, 128], [100, 130], [110, 128],
  ];
  return positions
      .map((p) => '<circle cx="${p[0]}" cy="${p[1]}" r="0.9" fill="$color" opacity="0.65"/>')
      .join();
}
