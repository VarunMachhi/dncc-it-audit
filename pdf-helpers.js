// DNCC PDF helpers — shared visual style for every generated PDF.
// Loaded by both index.html and admin.html via <script src="pdf-helpers.js">.
// Requires jsPDF to already be loaded (window.jspdf.jsPDF).
window.DNCCPdf = (function () {
  var NAVY = [19, 38, 53];
  var ACCENT = [44, 111, 151];
  var AMBER = [181, 105, 31];
  var AMBER_BG = [251, 238, 225];
  var ISSUE = [44, 111, 151];
  var ISSUE_BG = [234, 242, 246];
  var ROW_BG = [246, 247, 248];
  var TEXT = [20, 30, 40];
  var SOFT = [90, 100, 110];
  var LINE = [215, 221, 225];
  var PAGE_BOTTOM = 790;

  function drawMainHeader(ctx) {
    var doc = ctx.doc;
    doc.setFillColor(NAVY[0], NAVY[1], NAVY[2]);
    doc.rect(0, 0, ctx.pageWidth, 68, "F");
    doc.setTextColor(255, 255, 255);
    doc.setFont("helvetica", "bold");
    doc.setFontSize(16);
    doc.text(ctx.companyName, ctx.left, 32);
    doc.setFont("helvetica", "normal");
    doc.setFontSize(10.5);
    doc.text(ctx.department + "  •  " + ctx.title, ctx.left, 50);
    doc.setTextColor(TEXT[0], TEXT[1], TEXT[2]);
  }

  function drawContinuationHeader(ctx) {
    var doc = ctx.doc;
    doc.setFillColor(NAVY[0], NAVY[1], NAVY[2]);
    doc.rect(0, 0, ctx.pageWidth, 42, "F");
    doc.setTextColor(255, 255, 255);
    doc.setFont("helvetica", "bold");
    doc.setFontSize(11.5);
    doc.text(ctx.companyName, ctx.left, 20);
    doc.setFont("helvetica", "normal");
    doc.setFontSize(8.8);
    doc.text(ctx.title + "  •  Continued", ctx.left, 33);
    doc.setTextColor(TEXT[0], TEXT[1], TEXT[2]);
  }

  function newDoc(companyName, department, title) {
    var jsPDFCtor = window.jspdf.jsPDF;
    var doc = new jsPDFCtor({ unit: "pt", format: "a4" });
    var pageWidth = doc.internal.pageSize.getWidth();
    var left = 44, right = pageWidth - 44;
    var ctx = {
      doc: doc,
      y: 98,
      left: left,
      right: right,
      pageWidth: pageWidth,
      rowIndex: 0,
      companyName: companyName,
      department: department,
      title: title
    };
    drawMainHeader(ctx);
    return ctx;
  }

  function addPage(ctx) {
    ctx.doc.addPage();
    drawContinuationHeader(ctx);
    ctx.y = 68;
    ctx.rowIndex = 0;
  }

  function ensureSpace(ctx, needed) {
    if (ctx.y + needed > PAGE_BOTTOM) addPage(ctx);
  }

  function safeText(value) {
    return String(value === undefined || value === null || value === "" ? "—" : value);
  }

  function wrap(doc, value, width) {
    var text = safeText(value);
    return doc.splitTextToSize(text, Math.max(40, width));
  }

  function section(ctx, label) {
    // Keep the section heading together with at least one normal row.
    ensureSpace(ctx, 48);
    ctx.y += 10;
    ctx.doc.setFillColor(ACCENT[0], ACCENT[1], ACCENT[2]);
    ctx.doc.rect(ctx.left, ctx.y - 10, 4, 14, "F");
    ctx.doc.setFont("helvetica", "bold");
    ctx.doc.setFontSize(11.5);
    ctx.doc.setTextColor(NAVY[0], NAVY[1], NAVY[2]);
    ctx.doc.text(label, ctx.left + 11, ctx.y);
    ctx.doc.setTextColor(TEXT[0], TEXT[1], TEXT[2]);
    ctx.y += 14;
    ctx.rowIndex = 0;
  }

  function row(ctx, label, value) {
    var doc = ctx.doc;
    var valueX = ctx.left + 165;
    var valueWidth = ctx.right - valueX - 9;

    doc.setFont("helvetica", "normal");
    doc.setFontSize(10.3);
    var valueLines = wrap(doc, value, valueWidth);
    var lineHeight = 12.2;
    var rowH = Math.max(19, 9 + (valueLines.length * lineHeight));

    // A row is treated as one block. If it cannot fit, it starts on the next page.
    ensureSpace(ctx, rowH + 2);

    var top = ctx.y - 13;
    if (ctx.rowIndex % 2 === 0) {
      doc.setFillColor(ROW_BG[0], ROW_BG[1], ROW_BG[2]);
      doc.rect(ctx.left, top, ctx.right - ctx.left, rowH, "F");
    }

    doc.setFont("helvetica", "bold");
    doc.setFontSize(8.7);
    doc.setTextColor(SOFT[0], SOFT[1], SOFT[2]);
    doc.text(String(label || "").toUpperCase(), ctx.left + 9, top + 12);

    doc.setFont("helvetica", "normal");
    doc.setFontSize(10.3);
    doc.setTextColor(TEXT[0], TEXT[1], TEXT[2]);
    doc.text(valueLines, valueX, top + 12, { lineHeightFactor: 1.15 });

    ctx.y = top + rowH + 13;
    ctx.rowIndex++;
  }

  function damageBlock(ctx, what, how) {
    var doc = ctx.doc;
    var textWidth = ctx.right - ctx.left - 18;

    doc.setFont("helvetica", "normal");
    doc.setFontSize(9.7);
    var whatLines = wrap(doc, "What: " + (what || "—"), textWidth);
    var causeLines = wrap(doc, "Cause: " + (how || "—"), textWidth);
    var lineHeight = 11.7;
    var h = 29 + ((whatLines.length + causeLines.length) * lineHeight);

    // Keep the entire damage paragraph together. It will move to the next page
    // rather than being split or painted over the footer.
    ensureSpace(ctx, h + 18);
    ctx.y += 8;
    var top = ctx.y - 12;

    doc.setFillColor(AMBER_BG[0], AMBER_BG[1], AMBER_BG[2]);
    doc.rect(ctx.left, top, ctx.right - ctx.left, h, "F");
    doc.setFont("helvetica", "bold");
    doc.setFontSize(8.7);
    doc.setTextColor(AMBER[0], AMBER[1], AMBER[2]);
    doc.text("REPORTED DAMAGE", ctx.left + 9, top + 13);

    doc.setFont("helvetica", "normal");
    doc.setFontSize(9.7);
    doc.setTextColor(70, 48, 22);
    var textY = top + 28;
    doc.text(whatLines, ctx.left + 9, textY, { lineHeightFactor: 1.15 });
    textY += whatLines.length * lineHeight + 4;
    doc.text(causeLines, ctx.left + 9, textY, { lineHeightFactor: 1.15 });

    ctx.y = top + h + 18;
    ctx.rowIndex = 0;
  }


  function problemBlock(ctx, details) {
    var doc = ctx.doc;
    var textWidth = ctx.right - ctx.left - 18;

    doc.setFont("helvetica", "normal");
    doc.setFontSize(9.7);
    var lines = wrap(doc, details || "—", textWidth);
    var lineHeight = 11.7;
    var h = 29 + (lines.length * lineHeight);

    // Keep the complete issue description together on one page.
    ensureSpace(ctx, h + 18);
    ctx.y += 8;
    var top = ctx.y - 12;

    doc.setFillColor(ISSUE_BG[0], ISSUE_BG[1], ISSUE_BG[2]);
    doc.rect(ctx.left, top, ctx.right - ctx.left, h, "F");
    doc.setFont("helvetica", "bold");
    doc.setFontSize(8.7);
    doc.setTextColor(ISSUE[0], ISSUE[1], ISSUE[2]);
    doc.text("REPORTED PHONE PROBLEM", ctx.left + 9, top + 13);

    doc.setFont("helvetica", "normal");
    doc.setFontSize(9.7);
    doc.setTextColor(TEXT[0], TEXT[1], TEXT[2]);
    doc.text(lines, ctx.left + 9, top + 28, { lineHeightFactor: 1.15 });

    ctx.y = top + h + 18;
    ctx.rowIndex = 0;
  }

  function footer(ctx, note) {
    var doc = ctx.doc;
    doc.setFont("helvetica", "italic");
    doc.setFontSize(8.3);
    var lines = wrap(doc, note, ctx.right - ctx.left);
    var h = 28 + (lines.length * 10);
    ensureSpace(ctx, h);

    ctx.y += 14;
    doc.setDrawColor(LINE[0], LINE[1], LINE[2]);
    doc.line(ctx.left, ctx.y, ctx.right, ctx.y);
    ctx.y += 15;
    doc.setTextColor(SOFT[0], SOFT[1], SOFT[2]);
    doc.text(lines, ctx.left, ctx.y, { lineHeightFactor: 1.15 });
    ctx.y += lines.length * 10;
  }

  function toBase64(ctx) {
    return ctx.doc.output("datauristring").split(",")[1];
  }

  function save(ctx, filename) {
    ctx.doc.save(filename);
  }

  return {
    newDoc: newDoc,
    section: section,
    row: row,
    damageBlock: damageBlock,
    problemBlock: problemBlock,
    footer: footer,
    toBase64: toBase64,
    save: save
  };
})();
