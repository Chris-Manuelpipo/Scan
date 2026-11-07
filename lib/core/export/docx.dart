import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// Writes a minimal Word document: the [title] as a heading, then one
/// section per page of recognised text, separated by page breaks.
Future<File> writeDocx({
  required String path,
  required String title,
  required List<String> pages,
}) async {
  final body = StringBuffer()..write(_paragraph(title, style: 'Title'));
  for (final (i, text) in pages.indexed) {
    if (i > 0) body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
    final paragraphs = text.trim().split(RegExp(r'\n\s*\n'));
    for (final paragraph in paragraphs) {
      body.write(_paragraph(paragraph));
    }
  }

  final archive = Archive()
    ..add(_file('[Content_Types].xml', _contentTypes))
    ..add(_file('_rels/.rels', _rootRels))
    ..add(_file('word/_rels/document.xml.rels', _documentRels))
    ..add(_file('word/styles.xml', _styles))
    ..add(
      _file(
        'word/document.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<w:document xmlns:w="$_ns"><w:body>$body'
            '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
            '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" '
            'w:left="1134" w:header="0" w:footer="0" w:gutter="0"/>'
            '</w:sectPr></w:body></w:document>',
      ),
    );
  return File(path).writeAsBytes(ZipEncoder().encodeBytes(archive));
}

/// Lines inside a paragraph are kept with soft line breaks.
String _paragraph(String text, {String? style}) {
  final runs = [
    for (final line in text.split('\n'))
      '<w:r><w:t xml:space="preserve">${_escape(line)}</w:t></w:r>',
  ].join('<w:r><w:br/></w:r>');
  final props = style == null
      ? ''
      : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>';
  return '<w:p>$props$runs</w:p>';
}

/// XML-escapes and drops control characters Word refuses.
String _escape(String text) => const HtmlEscape(
  HtmlEscapeMode.element,
).convert(text).replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

ArchiveFile _file(String name, String content) =>
    ArchiveFile.bytes(name, utf8.encode(content));

const _ns = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

const _contentTypes =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
    '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
    '</Types>';

const _rootRels =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
    '</Relationships>';

const _documentRels =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '</Relationships>';

const _styles =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:styles xmlns:w="$_ns">'
    '<w:docDefaults><w:rPrDefault><w:rPr>'
    '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>'
    '<w:sz w:val="22"/><w:lang w:val="fr-FR"/></w:rPr></w:rPrDefault>'
    '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/>'
    '</w:pPr></w:pPrDefault></w:docDefaults>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
    '<w:name w:val="Normal"/></w:style>'
    '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>'
    '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/>'
    '<w:pPr><w:spacing w:after="240"/></w:pPr>'
    '<w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>'
    '</w:styles>';
