# zaiki_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Security Rules Deployment

This project uses local Firebase Security Rules files:

- Firestore: `firestore.rules`
- Storage: `storage.rules`

Deploy rules with:

```bash
firebase deploy --only firestore:rules,storage
```

If you deploy Hosting too, use:

```bash
firebase deploy
```

## Server-side PDF optimization (Cloud Functions)

PDF files uploaded under `bookings/*.pdf` are optimized on the server.

Setup and deploy:

```bash
cd functions
npm install
cd ..
firebase deploy --only functions
```

Then deploy rules as needed:

```bash
firebase deploy --only firestore:rules,storage
```

　
