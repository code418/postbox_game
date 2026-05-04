import 'avatar_config.dart';
import 'avatar_parts.dart';

/// Build the SVG string for an avatar, ready for `SvgPicture.string`.
///
/// Layer order (back → front): background, uniform, neck, ears, face, blush,
/// stubble (if any), beard (if any), mouth, nose, eyebrows, eyes, hair,
/// glasses, hat. Everything inside the head/uniform group is clipped to the
/// outer circle so hair and shoulders don't spill.
String buildAvatarSvg(AvatarConfig cfg) {
  final skin = avatarSkin[cfg[AvatarSlot.skin]];
  final head = avatarHeads[cfg[AvatarSlot.head]];
  final hair = avatarHair[cfg[AvatarSlot.hair]];
  final hairColor = avatarHairColors[cfg[AvatarSlot.hairColor]];
  final eyes = avatarEyes[cfg[AvatarSlot.eyes]];
  final nose = avatarNoses[cfg[AvatarSlot.nose]];
  final facial = avatarFacial[cfg[AvatarSlot.facial]];
  final glasses = avatarGlasses[cfg[AvatarSlot.glasses]];
  final hat = avatarHats[cfg[AvatarSlot.hat]];
  final bg = avatarBackgrounds[cfg[AvatarSlot.background]];

  const stroke = '#1a1a1a';
  const strokeW = '2.2';
  final shade = skin.shade ?? skin.fill;

  String facialLayer = '';
  if (facial.stubble) {
    facialLayer = avatarStubbleSvg(hairColor.fill);
  } else if (facial.path != null) {
    facialLayer =
        '<path d="${facial.path}" fill="${hairColor.fill}" stroke="$stroke" stroke-width="1.6" stroke-linejoin="round"/>';
  }

  final noseFill = nose.filled ? shade : 'none';

  return '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">
  <defs>
    <clipPath id="cc"><circle cx="100" cy="100" r="99"/></clipPath>
  </defs>
  <circle cx="100" cy="100" r="99" fill="${bg.fill}" stroke="$stroke" stroke-width="2"/>
  <g clip-path="url(#cc)">
    <g opacity="0.08">
      <circle cx="30" cy="40" r="0.8" fill="$stroke"/>
      <circle cx="170" cy="50" r="0.8" fill="$stroke"/>
      <circle cx="50" cy="170" r="0.8" fill="$stroke"/>
      <circle cx="160" cy="160" r="0.8" fill="$stroke"/>
      <circle cx="100" cy="30" r="0.6" fill="$stroke"/>
    </g>
    $avatarUniformSvg
    ${avatarNeckSvg(skin.fill, shade)}
    <path d="${head.earL}" fill="${skin.fill}" stroke="$stroke" stroke-width="$strokeW" stroke-linecap="round"/>
    <path d="${head.earR}" fill="${skin.fill}" stroke="$stroke" stroke-width="$strokeW" stroke-linecap="round"/>
    <path d="${head.face}" fill="${skin.fill}" stroke="$stroke" stroke-width="$strokeW" stroke-linejoin="round"/>
    <ellipse cx="76" cy="104" rx="5" ry="3" fill="$shade" opacity="0.45"/>
    <ellipse cx="124" cy="104" rx="5" ry="3" fill="$shade" opacity="0.45"/>
    $facialLayer
    <path d="M 90 124 Q 100 130 110 124" fill="none" stroke="$stroke" stroke-width="1.8" stroke-linecap="round"/>
    <path d="${nose.path}" fill="$noseFill" stroke="$stroke" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
    <g opacity="0.85">
      <path d="M 74 80 Q 82 77 90 80" fill="none" stroke="${hairColor.fill}" stroke-width="2.2" stroke-linecap="round"/>
      <path d="M 110 80 Q 118 77 126 80" fill="none" stroke="${hairColor.fill}" stroke-width="2.2" stroke-linecap="round"/>
    </g>
    ${eyes.svg}
    ${hair.path != null ? '<path d="${hair.path}" fill="${hairColor.fill}" stroke="$stroke" stroke-width="$strokeW" stroke-linejoin="round"/>' : ''}
    ${glasses.svg ?? ''}
    ${hat.svg ?? ''}
  </g>
  <circle cx="100" cy="100" r="99" fill="none" stroke="$stroke" stroke-width="2"/>
</svg>
''';
}
