import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';

/// Public URL of the hosted copy (served by Firebase Hosting from
/// web/privacy-policy.html — test/privacy_policy_sync_test.dart pins the two
/// documents against each other). Also used for the Play Store listing.
const String kHostedPrivacyPolicyUrl =
    'https://the-postbox-game.web.app/privacy-policy';

enum PolicyBlockType { title, heading, bullet, paragraph }

/// One rendered block of the markdown-lite policy document.
class PolicyBlock {
  const PolicyBlock(this.type, this.text);
  final PolicyBlockType type;
  final String text;
}

/// Parse the bundled policy markdown into renderable blocks. Markdown-lite
/// only: `# ` title, `## ` headings, `- ` bullets, blank-line-separated
/// paragraphs; `**bold**`/`_italic_` markers are stripped to plain text (no
/// markdown dependency — flutter_markdown is discontinued).
List<PolicyBlock> parsePolicyBlocks(String md) {
  final blocks = <PolicyBlock>[];
  final para = StringBuffer();

  void flushPara() {
    if (para.isEmpty) return;
    blocks.add(PolicyBlock(PolicyBlockType.paragraph, _cleanInline(para.toString())));
    para.clear();
  }

  for (final raw in md.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      flushPara();
    } else if (line.startsWith('## ')) {
      flushPara();
      blocks.add(PolicyBlock(PolicyBlockType.heading, _cleanInline(line.substring(3))));
    } else if (line.startsWith('# ')) {
      flushPara();
      blocks.add(PolicyBlock(PolicyBlockType.title, _cleanInline(line.substring(2))));
    } else if (line.startsWith('- ')) {
      flushPara();
      blocks.add(PolicyBlock(PolicyBlockType.bullet, _cleanInline(line.substring(2))));
    } else {
      if (para.isNotEmpty) para.write(' ');
      para.write(line);
    }
  }
  flushPara();
  return blocks;
}

/// Strip `**bold**` markers and enclosing `_italics_` to plain text.
String _cleanInline(String s) {
  var out = s.replaceAll('**', '').trim();
  if (out.startsWith('_')) out = out.substring(1);
  if (out.endsWith('_')) out = out.substring(0, out.length - 1);
  return out.trim();
}

/// In-app privacy policy, rendered from assets/legal/privacy_policy.md.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key, @visibleForTesting this.markdownOverride});

  /// Test seam — bypasses rootBundle so widget tests need no asset bundle.
  final String? markdownOverride;

  Future<String> _load() async {
    if (markdownOverride != null) return markdownOverride!;
    return rootBundle.loadString('assets/legal/privacy_policy.md');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy policy'),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Open in browser',
            onPressed: () => launchUrl(
              Uri.parse(kHostedPrivacyPolicyUrl),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _load(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final blocks = parsePolicyBlocks(snapshot.data!);
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: blocks.length,
            itemBuilder: (context, i) {
              final b = blocks[i];
              switch (b.type) {
                case PolicyBlockType.title:
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(b.text, style: theme.textTheme.headlineSmall),
                  );
                case PolicyBlockType.heading:
                  return Padding(
                    padding: const EdgeInsets.only(top: 20, bottom: 6),
                    child: Text(
                      b.text,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: theme.colorScheme.primary),
                    ),
                  );
                case PolicyBlockType.bullet:
                  return Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('•  '),
                        Expanded(
                            child:
                                Text(b.text, style: theme.textTheme.bodyMedium)),
                      ],
                    ),
                  );
                case PolicyBlockType.paragraph:
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(b.text, style: theme.textTheme.bodyMedium),
                  );
              }
            },
          );
        },
      ),
    );
  }
}
