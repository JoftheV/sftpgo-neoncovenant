const express = require('express');
const fs = require('fs');
const {
  SignedDataVerifier,
  Environment
} = require('@apple/app-store-server-library');

const app = express();
app.use(express.json());

const APPLE_ROOT_CA_PATHS = [
  process.env.APPLE_ROOT_CA_G3_PATH
].filter(Boolean);

function loadAppleRootCAs() {
  return APPLE_ROOT_CA_PATHS.map((p) => fs.readFileSync(p));
}

function getAppleEnvironment() {
  return process.env.APPLE_ENVIRONMENT === 'production'
    ? Environment.PRODUCTION
    : Environment.SANDBOX;
}

function buildSignedDataVerifier() {
  const appleRootCAs = loadAppleRootCAs();
  const enableOnlineChecks = true;
  const environment = getAppleEnvironment();
  const bundleId = process.env.APPLE_BUNDLE_ID;

  // Required by Apple library in production, optional in sandbox depending on flow.
  const appAppleId = process.env.APPLE_APP_ID
    ? Number(process.env.APPLE_APP_ID)
    : undefined;

  return new SignedDataVerifier(
    appleRootCAs,
    enableOnlineChecks,
    environment,
    bundleId,
    appAppleId
  );
}

const verifier = buildSignedDataVerifier();

async function verifyAppleNotification(signedPayload) {
  const verifiedNotification = await verifier.verifyAndDecodeNotification(signedPayload);

  let verifiedTransactionInfo = null;
  let verifiedRenewalInfo = null;

  if (verifiedNotification?.data?.signedTransactionInfo) {
    verifiedTransactionInfo = await verifier.verifyAndDecodeTransaction(
      verifiedNotification.data.signedTransactionInfo
    );
  }

  if (verifiedNotification?.data?.signedRenewalInfo) {
    verifiedRenewalInfo = await verifier.verifyAndDecodeRenewalInfo(
      verifiedNotification.data.signedRenewalInfo
    );
  }

  return {
    notification: verifiedNotification,
    transactionInfo: verifiedTransactionInfo,
    renewalInfo: verifiedRenewalInfo
  };
}

async function applyAppleNotification({ notification, transactionInfo, renewalInfo }) {
  const notificationType = notification.notificationType;
  const subtype = notification.subtype || null;

  const originalTransactionId =
    transactionInfo?.originalTransactionId || null;

  const latestTransactionId =
    transactionInfo?.transactionId || null;

  const productId =
    transactionInfo?.productId || renewalInfo?.autoRenewProductId || null;

  const expiresDate =
    transactionInfo?.expiresDate || null;

  const statusSummary = {
    notificationType,
    subtype,
    originalTransactionId,
    latestTransactionId,
    productId,
    expiresDate
  };

  console.log('Verified Apple notification:', statusSummary);

  // Example DB logic:
  // - DID_RENEW / SUBSCRIBED => mark entitlement active
  // - EXPIRED / REVOKE => mark inactive
  // - DID_FAIL_TO_RENEW => grace/retry handling
  // - REFUND => revoke or downgrade access according to your policy
}

app.post('/webhooks/apple', async (req, res) => {
  try {
    const { signedPayload } = req.body;

    if (!signedPayload || typeof signedPayload !== 'string') {
      return res.status(400).json({
        error: 'invalid_request',
        message: 'signedPayload is required'
      });
    }

    const verified = await verifyAppleNotification(signedPayload);

    await applyAppleNotification(verified);

    return res.status(200).json({ ok: true });
  } catch (err) {
    console.error('Apple webhook verification failed:', err);

    return res.status(400).json({
      error: 'invalid_signed_payload',
      message: err.message
    });
  }
});

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`Listening on port ${port}`);
});
