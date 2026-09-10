// DNCC PDF helpers — shared visual style for every generated PDF.
// Loaded by both index.html and admin.html via <script src="pdf-helpers.js">.
// Requires jsPDF to already be loaded (window.jspdf.jsPDF).
window.DNCCPdf = (function () {
  var NAVY = [19, 38, 53];
  var ACCENT = [44, 111, 151];
  var AMBER = [181, 105, 31];
  var AMBER_BG = [251, 238, 225];
  var ROW_BG = [246, 247, 248];
  var TEXT = [20, 30, 40];
  var SOFT = [90, 100, 110];
  var LINE = [215, 221, 225];

  function newDoc(companyName, department, title) {
    var jsPDFCtor = window.jspdf.jsPDF;
    var doc = new jsPDFCtor({ unit: "pt", format: "a4" });
    var pageWidth = doc.internal.pageSize.getWidth();
    var left = 44, right = pageWidth - 44;

    doc.setFillColor(NAVY[0], NAVY[1], NAVY[2]);
    doc.rect(0, 0, pageWidth, 68, "F");
    doc.setTextColor(255, 255, 255);
    doc.setFont("helvetica", "bold");
    doc.setFontSize(16);
    doc.text(companyName, left, 32);
    doc.setFont("helvetica", "normal");
    doc.setFontSize(10.5);
    doc.text(department + "  •  " + title, left, 50);
    doc.setTextColor(TEXT[0], TEXT[1], TEXT[2]);

    return { doc: doc, y: 98, left: left, right: right, pageWidth: pageWidth, rowIndex: 0, companyName: companyName, department: department };
  }

  function ensureSpace(ctx, needed) {
    if (ctx.y + needed > 790) {
      ctx.doc.addPage();
      ctx.y = 50;
      ctx.rowIndex = 0;
    }
  }

  function section(ctx, label) {
    ensureSpace(ctx, 30);
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
    ensureSpace(ctx, 20);
    var rowH = 19;
    if (ctx.rowIndex % 2 === 0) {
      ctx.doc.setFillColor(ROW_BG[0], ROW_BG[1], ROW_BG[2]);
      ctx.doc.rect(ctx.left, ctx.y - 13, ctx.right - ctx.left, rowH, "F");
    }
    ctx.doc.setFont("helvetica", "bold");
    ctx.doc.setFontSize(8.7);
    ctx.doc.setTextColor(SOFT[0], SOFT[1], SOFT[2]);
    ctx.doc.text(String(label || "").toUpperCase(), ctx.left + 9, ctx.y - 2);
    ctx.doc.setFont("helvetica", "normal");
    ctx.doc.setFontSize(10.5);
    ctx.doc.setTextColor(TEXT[0], TEXT[1], TEXT[2]);
    ctx.doc.text(String(value === undefined || value === null || value === "" ? "—" : value), ctx.left + 165, ctx.y - 2);
    ctx.y += rowH;
    ctx.rowIndex++;
  }

  function damageBlock(ctx, what, how) {
    ensureSpace(ctx, 60);
    ctx.y += 8;
    var h = 46;
    ctx.doc.setFillColor(AMBER_BG[0], AMBER_BG[1], AMBER_BG[2]);
    ctx.doc.rect(ctx.left, ctx.y - 12, ctx.right - ctx.left, h, "F");
    ctx.doc.setFont("helvetica", "bold");
    ctx.doc.setFontSize(8.7);
    ctx.doc.setTextColor(AMBER[0], AMBER[1], AMBER[2]);
    ctx.doc.text("REPORTED DAMAGE", ctx.left + 9, ctx.y);
    ctx.doc.setFont("helvetica", "normal");
    ctx.doc.setFontSize(9.7);
    ctx.doc.setTextColor(70, 48, 22);
    ctx.doc.text("What: " + (what || "—"), ctx.left + 9, ctx.y + 14, { maxWidth: ctx.right - ctx.left - 18 });
    ctx.doc.text("Cause: " + (how || "—"), ctx.left + 9, ctx.y + 28, { maxWidth: ctx.right - ctx.left - 18 });
    ctx.y += h + 6;
    ctx.rowIndex = 0;
  }

  function footer(ctx, note) {
    ensureSpace(ctx, 40);
    ctx.y += 14;
    ctx.doc.setDrawColor(LINE[0], LINE[1], LINE[2]);
    ctx.doc.line(ctx.left, ctx.y, ctx.right, ctx.y);
    ctx.y += 15;
    ctx.doc.setFont("helvetica", "italic");
    ctx.doc.setFontSize(8.3);
    ctx.doc.setTextColor(SOFT[0], SOFT[1], SOFT[2]);
    ctx.doc.text(note, ctx.left, ctx.y, { maxWidth: ctx.right - ctx.left });
  }

  function toBase64(ctx) {
    return ctx.doc.output("datauristring").split(",")[1];
  }

  function save(ctx, filename) {
    ctx.doc.save(filename);
  }

  return { newDoc: newDoc, section: section, row: row, damageBlock: damageBlock, footer: footer, toBase64: toBase64, save: save };
})();
