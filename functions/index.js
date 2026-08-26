const functions = require("firebase-functions/v1");
const logger = require("firebase-functions/logger");
const { initializeApp } = require("firebase-admin/app");
const { getStorage } = require("firebase-admin/storage");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { PDFDocument } = require("pdf-lib");

initializeApp();
const db = getFirestore();

exports.notifyBookingCreated = functions.firestore
  .document("bookings/{bookingId}")
  .onCreate(async (snapshot, context) => {
    const bookingId = context.params.bookingId;
    const data = snapshot.data() || {};

    const customerName = (data.customerName || "").toString().trim();
    const venueName = (data.venueName || "").toString().trim();
    const bookingDate = (data.bookingDate || "").toString().trim();

    const title = "予約履歴が追加されました";
    const bodyParts = [customerName, venueName, bookingDate].filter(Boolean);
    const body = bodyParts.length > 0
      ? bodyParts.join(" / ")
      : "新しい予約が登録されています。";

    try {
      const tokenSnapshot = await db
        .collection("notificationTokens")
        .where("enabled", "==", true)
        .limit(500)
        .get();

      const tokens = tokenSnapshot.docs
        .map((doc) => (doc.data().token || "").toString().trim())
        .filter(Boolean);

      if (tokens.length === 0) {
        logger.info("Skipped booking notification (no target tokens)", {
          bookingId,
        });
        return;
      }

      const multicastMessage = {
        tokens,
        notification: { title, body },
        data: {
          type: "booking_created",
          bookingId: bookingId,
          title: title,
          body: body,
        },
        android: {
          priority: "high",
          notification: {
            sound: "default",
          },
        },
        apns: {
          headers: {
            "apns-priority": "10",
          },
          payload: {
            aps: {
              sound: "default",
            },
          },
        },
      };

      const response = await getMessaging().sendEachForMulticast(
        multicastMessage,
      );

      const invalidDocRefs = [];
      response.responses.forEach((sendResult, index) => {
        if (sendResult.success) return;
        const code = sendResult.error?.code || "";
        if (
          code === "messaging/registration-token-not-registered" ||
          code === "messaging/invalid-registration-token"
        ) {
          const rawToken = tokens[index];
          const docId = rawToken.replaceAll("/", "_");
          invalidDocRefs.push(db.collection("notificationTokens").doc(docId));
        }
      });

      if (invalidDocRefs.length > 0) {
        const batch = db.batch();
        invalidDocRefs.forEach((ref) => {
          batch.set(
            ref,
            {
              enabled: false,
              disabledAt: FieldValue.serverTimestamp(),
            },
            { merge: true },
          );
        });
        await batch.commit();
      }

      logger.info("Sent booking notification", {
        bookingId,
        tokenCount: tokens.length,
        successCount: response.successCount,
        failureCount: response.failureCount,
      });
    } catch (error) {
      logger.error("Failed to send booking notification", {
        bookingId,
        error: String(error),
      });
    }
  });

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
