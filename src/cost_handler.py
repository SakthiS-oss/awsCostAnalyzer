"""
AWS Cost Anomaly Detection Lambda Handler
Processes SNS payloads from Cost Explorer anomaly monitors and CloudWatch billing alarms,
performs historical delta analysis via DynamoDB, and fires structured webhook alerts.
"""

import json
import os
import uuid
import logging
from datetime import datetime, timezone
from decimal import Decimal

import boto3
import urllib.request
import urllib.error

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["DYNAMODB_TABLE"]
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")
COST_THRESHOLD = float(os.environ.get("COST_THRESHOLD", "5.00"))


# ── Helpers ──────────────────────────────────────────────────────────────────

def _decimal(value):
    """Convert float to Decimal for DynamoDB."""
    return Decimal(str(value))


def _post_webhook(payload: dict) -> None:
    """Send a JSON payload to the configured Slack / Discord webhook URL."""
    if not SLACK_WEBHOOK_URL:
        logger.warning("No webhook URL configured — skipping notification.")
        return

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            logger.info("Webhook response: %s", resp.status)
    except urllib.error.URLError as exc:
        logger.error("Webhook delivery failed: %s", exc)


def _query_recent_anomalies(service: str, limit: int = 5) -> list:
    """
    Pull the most recent ledger entries for a given AWS service so we can
    decide whether this spike is cyclical or genuinely new.
    """
    table = dynamodb.Table(TABLE_NAME)
    resp = table.query(
        IndexName="ServiceDateIndex",
        KeyConditionExpression=boto3.dynamodb.conditions.Key("service").eq(service),
        ScanIndexForward=False,
        Limit=limit,
    )
    return resp.get("Items", [])


def _persist_anomaly(record: dict) -> None:
    """Write a structured anomaly record to the DynamoDB audit ledger."""
    table = dynamodb.Table(TABLE_NAME)
    table.put_item(Item=record)
    logger.info("Persisted anomaly record: %s", record["anomaly_id"])


def _build_slack_message(record: dict, is_cyclical: bool) -> dict:
    """Construct a Slack Block Kit message from the anomaly record."""
    emoji = "♻️" if is_cyclical else "🚨"
    status = "Likely cyclical pattern" if is_cyclical else "Potential runaway spend"
    color = "#FFA500" if is_cyclical else "#FF0000"

    return {
        "attachments": [
            {
                "color": color,
                "blocks": [
                    {
                        "type": "header",
                        "text": {
                            "type": "plain_text",
                            "text": f"{emoji} AWS Cost Anomaly Detected",
                        },
                    },
                    {
                        "type": "section",
                        "fields": [
                            {"type": "mrkdwn", "text": f"*Service:*\n`{record['service']}`"},
                            {"type": "mrkdwn", "text": f"*Status:*\n{status}"},
                            {"type": "mrkdwn", "text": f"*Impact ($):*\n${record['impact_amount']}"},
                            {"type": "mrkdwn", "text": f"*Threshold ($):*\n${COST_THRESHOLD}"},
                            {"type": "mrkdwn", "text": f"*Detected At:*\n{record['detected_at']}"},
                            {"type": "mrkdwn", "text": f"*Anomaly ID:*\n`{record['anomaly_id']}`"},
                        ],
                    },
                    {
                        "type": "context",
                        "elements": [
                            {
                                "type": "mrkdwn",
                                "text": f"Historical occurrences checked: {record.get('prior_occurrences', 0)}",
                            }
                        ],
                    },
                ],
            }
        ]
    }


# ── SNS message parsers ───────────────────────────────────────────────────────

def _parse_cost_anomaly(detail: dict) -> dict:
    """Parse a Cost Explorer anomaly monitor payload."""
    anomaly = detail.get("anomalyDetails", detail)
    return {
        "source": "cost_anomaly_monitor",
        "service": anomaly.get("dimensionValue", "Unknown"),
        "impact_amount": float(anomaly.get("impact", {}).get("totalImpact", 0)),
        "start_date": anomaly.get("anomalyStartDate", ""),
        "end_date": anomaly.get("anomalyEndDate", ""),
    }


def _parse_cloudwatch_alarm(detail: dict) -> dict:
    """Parse a CloudWatch Billing Alarm state-change payload."""
    metric = detail.get("configuration", {}).get("metrics", [{}])[0]
    namespace = metric.get("metricStat", {}).get("metric", {}).get("namespace", "AWS/Billing")
    service = (
        metric.get("metricStat", {}).get("metric", {}).get("dimensions", {}).get("ServiceName")
        or namespace
    )
    return {
        "source": "cloudwatch_alarm",
        "service": service,
        "impact_amount": float(detail.get("state", {}).get("value", 0)),
        "alarm_name": detail.get("alarmName", ""),
        "alarm_description": detail.get("configuration", {}).get("description", ""),
    }


# ── Lambda entrypoint ─────────────────────────────────────────────────────────

def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event))

    for sns_record in event.get("Records", []):
        raw_message = sns_record["Sns"]["Message"]

        try:
            message = json.loads(raw_message)
        except json.JSONDecodeError:
            logger.error("Failed to parse SNS message as JSON: %s", raw_message)
            continue

        # ── Determine payload type ──
        source_type = message.get("source", "")
        if "anomalyDetails" in message or source_type == "aws.ce":
            parsed = _parse_cost_anomaly(message)
        elif "alarmName" in message or source_type == "aws.cloudwatch":
            parsed = _parse_cloudwatch_alarm(message)
        else:
            logger.warning("Unknown message format — treating as generic alert.")
            parsed = {
                "source": "unknown",
                "service": message.get("service", "Unknown"),
                "impact_amount": float(message.get("impact_amount", 0)),
            }

        # ── Skip sub-threshold events ──
        if parsed["impact_amount"] < COST_THRESHOLD:
            logger.info(
                "Impact $%.2f below threshold $%.2f — skipping.",
                parsed["impact_amount"],
                COST_THRESHOLD,
            )
            continue

        # ── Historical delta analysis ──
        prior_records = _query_recent_anomalies(parsed["service"])
        prior_count = len(prior_records)
        is_cyclical = prior_count >= 2  # Seen ≥2 times before → likely cyclical

        # ── Build audit record ──
        now = datetime.now(timezone.utc).isoformat()
        anomaly_id = str(uuid.uuid4())
        record = {
            "anomaly_id": anomaly_id,
            "service": parsed["service"],
            "source": parsed["source"],
            "impact_amount": _decimal(parsed["impact_amount"]),
            "detected_at": now,
            "is_cyclical": is_cyclical,
            "prior_occurrences": prior_count,
            **{k: v for k, v in parsed.items() if k not in ("service", "source", "impact_amount")},
        }

        # ── Persist to DynamoDB ──
        _persist_anomaly(record)

        # ── Fire webhook notification ──
        slack_msg = _build_slack_message(
            {**record, "impact_amount": float(record["impact_amount"])},
            is_cyclical,
        )
        _post_webhook(slack_msg)

    return {"statusCode": 200, "body": "OK"}
