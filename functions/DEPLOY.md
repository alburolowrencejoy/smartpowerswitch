# Deploying Cloud Functions (Blaze required)

Prerequisites:
- Billing enabled for the Firebase project (Blaze plan).
- `gcloud` and `firebase-tools` installed and authenticated.
- Your local account has permission to enable APIs and deploy functions.

1. Set your project and authenticate:

```bash
gcloud auth login
gcloud config set project <YOUR_PROJECT_ID>
firebase login
```

2. Enable required Google Cloud APIs (Blaze required for scheduled jobs and external network):

```bash
gcloud services enable cloudscheduler.googleapis.com
gcloud services enable eventarc.googleapis.com
gcloud services enable pubsub.googleapis.com
gcloud services enable cloudfunctions.googleapis.com
gcloud services enable compute.googleapis.com
```

3. Install dependencies and test locally (optional):

```bash
cd functions
npm ci
npm run serve    # starts functions shell/emulator
```

4. Deploy functions:

```bash
cd functions
firebase deploy --only functions --project <YOUR_PROJECT_ID>
```

Notes:
- The project must be on Blaze for `onSchedule` scheduled triggers to create Cloud Scheduler jobs and to allow outbound network calls (used by `fetch_davao_light_rates`).
- If you run into permission errors, ensure your user has the necessary IAM roles (Editor or Owner) or grant the Cloud Functions service account appropriate roles for scheduler/eventarc.
- If deployment fails with `Access to bucket gcf-sources-<PROJECT_NUMBER>-us-central1 denied`, grant `Storage Object Viewer` to the Compute Engine default service account shown in the error (for example, `867230118403-compute@developer.gserviceaccount.com`) on the `gcf-sources-...` bucket, or fix any organization policy or VPC Service Controls perimeter that blocks it.
- For CI/CD use a service account key and set `GOOGLE_APPLICATION_CREDENTIALS` accordingly.
