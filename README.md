# sahelflow-lab

A test lab for SahelFlow on real Windows. A run starts only by hand: Actions, Run workflow, or the owner pushing a branch named `run/...`.
This repo holds no product code and no secrets.

**Logs are public.** Workflow logs show only step ok/fail and durations. Everything else a run learns is packed into
`results.enc` (AES-256-CBC, key wrapped with the RSA public key in `keys/`). Only the owner can open it.
