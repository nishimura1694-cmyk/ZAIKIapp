const functions = require("firebase-functions/v1");
const logger = require("firebase-functions/logger");
const { initializeApp } = require("firebase-admin/app");
const { getStorage } = require("firebase-admin/storage");
const { PDFDocument } = require("pdf-lib");

initializeApp();

exports.optimizeBookingPdf = functions.storage.object().onFinalize(async (object) => {
  const filePath = object.name || "";
  const contentType = (object.contentType || "").toLowerCase();
  const customMetadata = object.metadata || {};

  if (!filePath.startsWith("bookings/")) return;
  if (!filePath.toLowerCase().endsWith(".pdf")) return;
  if (contentType && contentType !== "application/pdf") return;
  if (customMetadata.optimized === "true") return;

  const bucket = getStorage().bucket(object.bucket);
  const file = bucket.file(filePath);

  const [exists] = await file.exists();
  if (!exists) return;

  const [originalBytes] = await file.download();
  if (originalBytes.length === 0) return;

  let optimizedBytes = null;
  try {
    const pdf = await PDFDocument.load(originalBytes, {
      ignoreEncryption: true,
      updateMetadata: false,
    });

    optimizedBytes = await pdf.save({
      useObjectStreams: true,
      addDefaultPage: false,
      updateFieldAppearances: false,
    });
  } catch (error) {
    logger.error("PDF parse/optimize failed", { filePath, error: String(error) });
    return;
  }

  if (!optimizedBytes || optimizedBytes.length >= originalBytes.length) {
    await file.setMetadata({
      metadata: {
        ...customMetadata,
        optimized: "true",
        optimizedAt: new Date().toISOString(),
        originalBytes: String(originalBytes.length),
        optimizedBytes: String(originalBytes.length),
      },
    });

    logger.info("Skipped (not smaller)", {
      filePath,
      originalBytes: originalBytes.length,
    });
    return;
  }

  await file.save(optimizedBytes, {
    resumable: false,
    metadata: {
      contentType: "application/pdf",
      metadata: {
        ...customMetadata,
        optimized: "true",
        optimizedAt: new Date().toISOString(),
        originalBytes: String(originalBytes.length),
        optimizedBytes: String(optimizedBytes.length),
      },
    },
  });

  logger.info("Optimized PDF", {
    filePath,
    originalBytes: originalBytes.length,
    optimizedBytes: optimizedBytes.length,
    savedBytes: originalBytes.length - optimizedBytes.length,
  });
});
