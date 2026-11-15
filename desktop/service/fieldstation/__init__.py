"""Field Station: desktop sensor capture and local geometry analysis.

This package is the DESKTOP surface of the project. It acquires depth/colour
from a sensor (Intel RealSense D435 first), writes reproducible scan bundles,
and computes local geometric measurements with units and limitations.

It deliberately contains no planetary analog discovery, terrain/geology
scoring or candidate ranking: that belongs to the website. A scan may carry a
website candidate or field-site ID as an opaque reference, nothing more.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""

APP_NAME = "Field Station"
APP_VERSION = "0.1.0"
SCHEMA_VERSION = "1.0"        # scan envelope / bundle manifest
PROTOCOL_VERSION = 1          # phone <-> desktop control messages
PIPELINE_VERSION = "fieldstation-pointcloud-1.0"
