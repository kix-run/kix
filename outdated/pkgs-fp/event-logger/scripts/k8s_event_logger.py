#!/usr/bin/env -S uv --quiet run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "kubernetes>=29.0.0",
#     "PyYAML>=5.3.1",
# ]
# ///
import json
from datetime import datetime, timezone
from typing import Any, Dict

from kubernetes import client, config, watch


class DateTimeEncoder(json.JSONEncoder):
    """Custom JSON encoder that can handle datetime objects."""

    def default(self, obj):
        if isinstance(obj, datetime):
            return obj.isoformat()
        return super().default(obj)


def format_event(event: Dict[str, Any]) -> Dict[str, Any]:
    """Format Kubernetes event for structured logging."""
    obj = event["object"]

    # Extract and format relevant fields
    formatted_event = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "type": obj.type,
        "reason": obj.reason,
        "message": obj.message,
        "count": obj.count,
        "namespace": obj.metadata.namespace,
        "name": obj.metadata.name,
        "uid": obj.metadata.uid,
        "involved_object_kind": obj.involved_object.kind,
        "involved_object_name": obj.involved_object.name,
        "involved_object_namespace": obj.involved_object.namespace,
        "involved_object_uid": obj.involved_object.uid,
        "involved_object_api_version": getattr(
            obj.involved_object, "api_version", None
        ),
        "first_timestamp": obj.first_timestamp,
        "last_timestamp": obj.last_timestamp,
        "event_time": getattr(obj, "event_time", None),
        "reporting_component": getattr(obj, "reporting_component", None),
        "source_component": (
            getattr(obj.source, "component", None) if hasattr(obj, "source") else None
        ),
    }

    # Clean None values for better JSON output
    return {k: v for k, v in formatted_event.items() if v is not None}


def main():
    """Watch and log all Kubernetes events as JSON."""
    # Load kubeconfig based on whether we're running in-cluster or not
    try:
        config.load_incluster_config()
        print(
            json.dumps(
                {"message": "Using in-cluster configuration"}, cls=DateTimeEncoder
            ),
            flush=True,
        )
    except config.ConfigException:
        config.load_kube_config()
        print(
            json.dumps({"message": "Using kubeconfig file"}, cls=DateTimeEncoder),
            flush=True,
        )

    # Create API client
    v1 = client.CoreV1Api()
    w = watch.Watch()

    print(
        json.dumps(
            {"message": "Starting to watch Kubernetes events"}, cls=DateTimeEncoder
        ),
        flush=True,
    )

    # Watch events across all namespaces
    for event in w.stream(v1.list_event_for_all_namespaces):
        formatted_event = format_event(event)
        print(json.dumps(formatted_event, cls=DateTimeEncoder), flush=True)


if __name__ == "__main__":
    main()
