# mAIPrompter

mAIPrompter is a browser-based teleprompter and creator recording studio built as a lightweight static web app.

## Features

- SaaS-style landing page
- Local sign-in preview with creator/admin account
- Safe teleprompter preview on the landing page
- Full teleprompter studio with script editing
- Camera and microphone selection
- External USB camera/mic support
- Pop-out reading window
- Voice-responsive scrolling
- Local browser recording through MediaRecorder
- Resolution controls and actual camera resolution readout
- Free-tier watermark logic for local preview

## Local Development

This project is intentionally zero-dependency.

```bash
python3 -m http.server 5174
```

Then open:

```text
http://localhost:5174/
```

## Deployment

This is a static site and can be deployed directly to Vercel.

## Production Notes

The current build is a local/static SaaS preview. Production SaaS functionality will need backend services for:

- Google/LinkedIn OAuth
- Email OTP delivery
- User/workspace database
- Subscription billing through Razorpay/Stripe
- Server-side usage enforcement
- Production analytics and admin dashboard data
