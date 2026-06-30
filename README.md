# AWS Cost Anomaly Detector

A fully serverless, event-driven pipeline that detects AWS cost spikes in real time,
performs historical delta analysis, and fires structured alerts to Slack or Discord —
at **$0.00/month** when idle.

```
[AWS Cost Explorer / CloudWatch Billing Alarms]
              │
              ▼
       [Amazon SNS Topic]  ──(async)──►  [AWS Lambda (Python 3.11)]
                                                    │
                               ┌────────────────────┴───────────────────┐
                               ▼                                        ▼
                  [Slack / Discord Webhook]                   [Amazon DynamoDB]
                   (Real-Time Alerting)                   (On-Demand Audit Ledger)
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform CLI | >= 1.5.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | >= 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Python | 3.11 (Lambda runtime only, not needed locally) | — |

You will also need:
- An AWS account with **billing alerts enabled** (Account → Billing Preferences → Receive Billing Alerts).
- IAM credentials with permissions to create Lambda, DynamoDB, SNS, S3, CloudWatch, IAM, and Cost Explorer resources.
- A **Slack or Discord incoming webhook URL**.

---

## Project Structure

```
├── terraform/
│   ├── main.tf                  # S3, DynamoDB, Lambda, packaging
│   ├── monitoring.tf            # SNS, Cost Anomaly Monitor, CloudWatch alarms
│   ├── iam.tf                   # Least-privilege execution roles
│   ├── variables.tf             # All configurable inputs
│   ├── outputs.tf               # Resource ARNs / names printed after apply
│   └── terraform.tfvars.example # Copy → terraform.tfvars and fill in secrets
├── src/
│   └── cost_handler.py          # Lambda: parse → analyse → alert → persist
└── README.md
```

---

## Setup — Step by Step

### 1 — Clone and enter the repo

```bash
git clone <your-repo-url>
cd aws-cost-anomaly-detector
```

### 2 — Enable Billing Alerts in your AWS account

> This is a one-time manual step required for CloudWatch Billing metrics to appear.

1. Sign in to the AWS Console.
2. Go to **Billing & Cost Management → Billing Preferences**.
3. Tick **"Receive Billing Alerts"** and save.

Allow up to 15 minutes for the `AWS/Billing` CloudWatch namespace to become active.

### 3 — Create a Slack (or Discord) webhook

**Slack:**
1. Visit https://api.slack.com/apps → **Create New App → From Scratch**.
2. Enable **Incoming Webhooks** and click **Add New Webhook to Workspace**.
3. Choose a channel and copy the `https://hooks.slack.com/services/…` URL.

**Discord:**
1. Open your server → channel settings → **Integrations → Webhooks → New Webhook**.
2. Copy the URL and append `/slack` to the end:
   `https://discord.com/api/webhooks/…/…/slack`

### 4 — Configure Terraform variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:

```hcl
slack_webhook_url       = "https://hooks.slack.com/services/T000/B000/XXXXXX"
cost_threshold          = 5.00    # Alert if any anomaly exceeds $5 absolute impact
billing_alarm_threshold = 50.00   # Alert if total estimated monthly bill exceeds $50
aws_region              = "us-east-1"   # Must be us-east-1 for billing metrics
alert_email             = ""      # Optional raw SNS email, leave blank to skip
```

> ⚠️ **Never commit `terraform.tfvars` to version control.** Add it to `.gitignore`.

### 5 — Configure AWS credentials

```bash
# Option A: named profile
export AWS_PROFILE=your-profile

# Option B: environment variables
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1
```

Verify access:

```bash
aws sts get-caller-identity
```

### 6 — Deploy

```bash
cd terraform/

# Download providers and initialise backend state
terraform init

# Preview every resource that will be created (read this carefully)
terraform plan

# Provision all infrastructure
terraform apply
```

Type `yes` when prompted (or use `--auto-approve` to skip).

After a successful apply you will see output similar to:

```
Outputs:
cloudwatch_log_group     = "/aws/lambda/cost-anomaly-detector-cost-handler"
cost_anomaly_monitor_arn = "arn:aws:ce::123456789012:anomalymonitor/..."
dynamodb_table_name      = "cost-anomaly-detector-anomaly-ledger"
lambda_function_name     = "cost-anomaly-detector-cost-handler"
s3_artifacts_bucket      = "cost-anomaly-detector-artifacts-123456789012"
sns_topic_arn            = "arn:aws:sns:us-east-1:123456789012:cost-anomaly-detector-cost-alerts"
```

### 7 — Confirm SNS email subscription (if configured)

If you set `alert_email`, AWS sends a confirmation email to that address.
Click **"Confirm subscription"** in that email before alerts will be delivered.

---

## Testing the Pipeline

### Trigger a manual test via AWS CLI

```bash
# Replace with your SNS ARN from the terraform output
SNS_ARN=$(terraform -chdir=terraform output -raw sns_topic_arn)

aws sns publish \
  --topic-arn "$SNS_ARN" \
  --message '{
    "source": "test",
    "service": "AmazonEC2",
    "impact_amount": 99.99
  }'
```

Check your Slack channel — an alert should arrive within ~10 seconds.

### Inspect Lambda logs

```bash
LOG_GROUP=$(terraform -chdir=terraform output -raw cloudwatch_log_group)

aws logs tail "$LOG_GROUP" --follow
```

### Inspect DynamoDB ledger

```bash
TABLE=$(terraform -chdir=terraform output -raw dynamodb_table_name)

aws dynamodb scan --table-name "$TABLE"
```

---

## Tearing Down

```bash
terraform destroy
```

All resources (Lambda, DynamoDB, SNS, S3, CloudWatch alarms, IAM roles) are removed.
DynamoDB data is permanently deleted — export it first if you need an audit trail.

---

## Architecture Notes

### Historical Delta Analysis
The Lambda handler queries the `ServiceDateIndex` GSI to retrieve the last 5 anomaly
records for the triggering service. If 2 or more prior records exist, the alert is
flagged as **cyclical** (e.g. end-of-month batch jobs), reducing noise for recurring
patterns while still creating an audit record.

### Cost at Idle
| Resource | Idle Cost |
|----------|-----------|
| Lambda | $0 (invocation-only pricing) |
| DynamoDB | $0 (pay-per-request, no traffic = no charge) |
| SNS | $0 (first 1 M publishes/month free) |
| S3 | ~$0.001/month (one small zip stored) |
| Cost Anomaly Monitor | $0 (free service) |
| CloudWatch Alarms | ~$0.10/alarm/month |

### Security
- Lambda IAM role is scoped to its specific DynamoDB table, log group, and S3 prefix only.
- SNS topic policy restricts publishers to `costalerts.amazonaws.com` and `cloudwatch.amazonaws.com`.
- S3 bucket has public access fully blocked and server-side encryption enabled.
- DynamoDB table has encryption at rest and point-in-time recovery enabled.
- `slack_webhook_url` is passed as a Lambda environment variable marked `sensitive = true`
  in Terraform and never written to logs.

---

## Customisation

| What | Where |
|------|-------|
| Add more watched services | `locals.watched_services` in `monitoring.tf` |
| Change alert threshold | `cost_threshold` in `terraform.tfvars` |
| Change cyclical detection sensitivity | `limit` and `is_cyclical` threshold in `cost_handler.py` |
| Add TTL to old DynamoDB records | Set `expires_at` (Unix epoch) in `_persist_anomaly()` |
| Route alerts to multiple channels | Add more `aws_sns_topic_subscription` blocks in `monitoring.tf` |
