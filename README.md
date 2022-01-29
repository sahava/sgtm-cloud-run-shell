# Cloud Run deployment for Server-side Google Tag Manager
This shell script automates the deployment of a Server-side Google Tag Manager environment with Cloud Run in the Google Cloud Platform.

## Deploy and run
The easiest way to utilize this script is to open a Google Cloud Platform project **Cloud Shell** instance, and then run the following command in the shell:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sahava/sgtm-cloud-run-shell/main/cr-script.sh)"
```

Just follow the prompts and you'll have a debug server and tagging server running in the region(s) you selected.
