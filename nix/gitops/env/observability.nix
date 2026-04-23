# nix/gitops/env/observability.nix
#
# Observability stack (ClickStack): unified logs, traces, metrics, and
# Hubble flow telemetry → ClickHouse (existing ch4 cluster, new `otel`
# database) → ClickStack UI (HyperDX). Design: docs/observability.md.
#
# This file grows across four PRs:
#   PR 1:  ArgoCD Application scaffold + namespace (landed).
#   PR 2:  OTel Collector DaemonSet + schema-bootstrap Job + placeholder
#          CH credentials Secret (landed).
#   PR 3:  split — PR 3a (Prom remoteWrite in nix/monitoring-module.nix,
#          landed) and PR 3b (hubble-otel DS, deferred — upstream image
#          is archived).
#   PR 4 (this commit): ClickStack UI (HyperDX + chart-provided MongoDB)
#                       + Cilium Ingress + Certificate + placeholder
#                       hyperdx-config Secret. Real CH creds land via
#                       the bootstrap-secrets script in
#                       nix/observability-scripts.nix.
#
{ pkgs, lib, helm }:
let
  constants = import ../../constants.nix;
  o         = constants.observability;
  ch        = o.clickhouse;
  ttl       = ch.ttl;

  # ─── Canonical tables exposed to ch4 via ReplicatedMergeTree ───────
  # DDL copied from opentelemetry-collector-contrib clickhouseexporter
  # (version pinned in o.clickhouseExporterVersion) and
  # transformed for the existing ch4 cluster:
  #   - ENGINE MergeTree()  →  ReplicatedMergeTree('/clickhouse/tables/{shard}/<name>', '{replica}')
  #   - add `ON CLUSTER ch4` so DDL fans out to every replica
  #   - TTL interval comes from constants.observability.clickhouse.ttl
  # A matching Distributed(ch4, otel, <name>, ...) wrapper is emitted
  # for each writable table; the collector writes to `*_dist` and CH
  # routes to the correct shard.
  cluster   = ch.cluster;
  onCluster = "ON CLUSTER ${cluster}";
  rmt       = name:
    "ReplicatedMergeTree('/clickhouse/tables/{shard}/${name}', '{replica}')";

  bootstrapSql = ''
    -- ─── Database ─────────────────────────────────────────────────
    CREATE DATABASE IF NOT EXISTS ${ch.database} ${onCluster};

    -- ─── Logs ─────────────────────────────────────────────────────
    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_logs ${onCluster} (
        Timestamp DateTime64(9) CODEC(Delta(8), ZSTD(1)),
        TimestampTime DateTime DEFAULT toDateTime(Timestamp),
        TraceId String CODEC(ZSTD(1)),
        SpanId String CODEC(ZSTD(1)),
        TraceFlags UInt8,
        SeverityText LowCardinality(String) CODEC(ZSTD(1)),
        SeverityNumber UInt8,
        ServiceName LowCardinality(String) CODEC(ZSTD(1)),
        Body String CODEC(ZSTD(1)),
        ResourceSchemaUrl LowCardinality(String) CODEC(ZSTD(1)),
        ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ScopeSchemaUrl LowCardinality(String) CODEC(ZSTD(1)),
        ScopeName String CODEC(ZSTD(1)),
        ScopeVersion LowCardinality(String) CODEC(ZSTD(1)),
        ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        LogAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
        INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_log_attr_key mapKeys(LogAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_log_attr_value mapValues(LogAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_body Body TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 8
    ) ENGINE = ${rmt "otel_logs"}
    PARTITION BY toDate(TimestampTime)
    PRIMARY KEY (ServiceName, TimestampTime)
    ORDER BY (ServiceName, TimestampTime, Timestamp)
    TTL TimestampTime + toIntervalDay(${toString ttl.logsDays})
    SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1;

    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_logs_dist ${onCluster}
    AS ${ch.database}.otel_logs
    ENGINE = Distributed(${cluster}, ${ch.database}, otel_logs, cityHash64(ServiceName));

    -- ─── Traces ───────────────────────────────────────────────────
    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_traces ${onCluster} (
        Timestamp DateTime64(9) CODEC(Delta, ZSTD(1)),
        TraceId String CODEC(ZSTD(1)),
        SpanId String CODEC(ZSTD(1)),
        ParentSpanId String CODEC(ZSTD(1)),
        TraceState String CODEC(ZSTD(1)),
        SpanName LowCardinality(String) CODEC(ZSTD(1)),
        SpanKind LowCardinality(String) CODEC(ZSTD(1)),
        ServiceName LowCardinality(String) CODEC(ZSTD(1)),
        ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ScopeName String CODEC(ZSTD(1)),
        ScopeVersion String CODEC(ZSTD(1)),
        SpanAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        Duration UInt64 CODEC(ZSTD(1)),
        StatusCode LowCardinality(String) CODEC(ZSTD(1)),
        StatusMessage String CODEC(ZSTD(1)),
        Events Nested (
            Timestamp DateTime64(9),
            Name LowCardinality(String),
            Attributes Map(LowCardinality(String), String)
        ) CODEC(ZSTD(1)),
        Links Nested (
            TraceId String,
            SpanId String,
            TraceState String,
            Attributes Map(LowCardinality(String), String)
        ) CODEC(ZSTD(1)),
        INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
        INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_span_attr_key mapKeys(SpanAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_span_attr_value mapValues(SpanAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_duration Duration TYPE minmax GRANULARITY 1
    ) ENGINE = ${rmt "otel_traces"}
    PARTITION BY toDate(Timestamp)
    ORDER BY (ServiceName, SpanName, toDateTime(Timestamp))
    TTL toDate(Timestamp) + toIntervalDay(${toString ttl.tracesDays})
    SETTINGS index_granularity=8192, ttl_only_drop_parts = 1;

    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_traces_trace_id_ts ${onCluster} (
         TraceId String CODEC(ZSTD(1)),
         Start DateTime CODEC(Delta, ZSTD(1)),
         End DateTime CODEC(Delta, ZSTD(1)),
         INDEX idx_trace_id TraceId TYPE bloom_filter(0.01) GRANULARITY 1
    ) ENGINE = ${rmt "otel_traces_trace_id_ts"}
    PARTITION BY toDate(Start)
    ORDER BY (TraceId, Start)
    TTL toDate(Start) + toIntervalDay(${toString ttl.tracesDays})
    SETTINGS index_granularity=8192, ttl_only_drop_parts = 1;

    CREATE MATERIALIZED VIEW IF NOT EXISTS ${ch.database}.otel_traces_trace_id_ts_mv ${onCluster}
    TO ${ch.database}.otel_traces_trace_id_ts
    AS SELECT
        TraceId,
        min(Timestamp) as Start,
        max(Timestamp) as End
    FROM ${ch.database}.otel_traces
    WHERE TraceId != '''
    GROUP BY TraceId;

    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_traces_dist ${onCluster}
    AS ${ch.database}.otel_traces
    ENGINE = Distributed(${cluster}, ${ch.database}, otel_traces, cityHash64(TraceId));

    -- ─── Metrics: gauge ───────────────────────────────────────────
    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_gauge ${onCluster} (
        ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ResourceSchemaUrl String CODEC(ZSTD(1)),
        ScopeName String CODEC(ZSTD(1)),
        ScopeVersion String CODEC(ZSTD(1)),
        ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ScopeDroppedAttrCount UInt32 CODEC(ZSTD(1)),
        ScopeSchemaUrl String CODEC(ZSTD(1)),
        ServiceName LowCardinality(String) CODEC(ZSTD(1)),
        MetricName String CODEC(ZSTD(1)),
        MetricDescription String CODEC(ZSTD(1)),
        MetricUnit String CODEC(ZSTD(1)),
        Attributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        StartTimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        TimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        Value Float64 CODEC(ZSTD(1)),
        Flags UInt32 CODEC(ZSTD(1)),
        Exemplars Nested (
            FilteredAttributes Map(LowCardinality(String), String),
            TimeUnix DateTime64(9),
            Value Float64,
            SpanId String,
            TraceId String
        ) CODEC(ZSTD(1)),
        INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1
    ) ENGINE = ${rmt "otel_metrics_gauge"}
    TTL toDateTime(TimeUnix) + toIntervalDay(${toString ttl.metricsDays})
    PARTITION BY toDate(TimeUnix)
    ORDER BY (ServiceName, MetricName, Attributes, toUnixTimestamp64Nano(TimeUnix))
    SETTINGS index_granularity=8192, ttl_only_drop_parts = 1;

    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_gauge_dist ${onCluster}
    AS ${ch.database}.otel_metrics_gauge
    ENGINE = Distributed(${cluster}, ${ch.database}, otel_metrics_gauge, cityHash64(ServiceName, MetricName));

    -- ─── Metrics: sum ─────────────────────────────────────────────
    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_sum ${onCluster} (
        ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ResourceSchemaUrl String CODEC(ZSTD(1)),
        ScopeName String CODEC(ZSTD(1)),
        ScopeVersion String CODEC(ZSTD(1)),
        ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ScopeDroppedAttrCount UInt32 CODEC(ZSTD(1)),
        ScopeSchemaUrl String CODEC(ZSTD(1)),
        ServiceName LowCardinality(String) CODEC(ZSTD(1)),
        MetricName String CODEC(ZSTD(1)),
        MetricDescription String CODEC(ZSTD(1)),
        MetricUnit String CODEC(ZSTD(1)),
        Attributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        StartTimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        TimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        Value Float64 CODEC(ZSTD(1)),
        Flags UInt32 CODEC(ZSTD(1)),
        Exemplars Nested (
            FilteredAttributes Map(LowCardinality(String), String),
            TimeUnix DateTime64(9),
            Value Float64,
            SpanId String,
            TraceId String
        ) CODEC(ZSTD(1)),
        AggregationTemporality Int32 CODEC(ZSTD(1)),
        IsMonotonic Boolean CODEC(Delta, ZSTD(1)),
        INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1
    ) ENGINE = ${rmt "otel_metrics_sum"}
    TTL toDateTime(TimeUnix) + toIntervalDay(${toString ttl.metricsDays})
    PARTITION BY toDate(TimeUnix)
    ORDER BY (ServiceName, MetricName, Attributes, toUnixTimestamp64Nano(TimeUnix))
    SETTINGS index_granularity=8192, ttl_only_drop_parts = 1;

    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_sum_dist ${onCluster}
    AS ${ch.database}.otel_metrics_sum
    ENGINE = Distributed(${cluster}, ${ch.database}, otel_metrics_sum, cityHash64(ServiceName, MetricName));

    -- ─── Metrics: summary ─────────────────────────────────────────
    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_summary ${onCluster} (
        ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ResourceSchemaUrl String CODEC(ZSTD(1)),
        ScopeName String CODEC(ZSTD(1)),
        ScopeVersion String CODEC(ZSTD(1)),
        ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ScopeDroppedAttrCount UInt32 CODEC(ZSTD(1)),
        ScopeSchemaUrl String CODEC(ZSTD(1)),
        ServiceName LowCardinality(String) CODEC(ZSTD(1)),
        MetricName String CODEC(ZSTD(1)),
        MetricDescription String CODEC(ZSTD(1)),
        MetricUnit String CODEC(ZSTD(1)),
        Attributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        StartTimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        TimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        Count UInt64 CODEC(Delta, ZSTD(1)),
        Sum Float64 CODEC(ZSTD(1)),
        ValueAtQuantiles Nested(
            Quantile Float64,
            Value Float64
        ) CODEC(ZSTD(1)),
        Flags UInt32 CODEC(ZSTD(1)),
        INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1
    ) ENGINE = ${rmt "otel_metrics_summary"}
    TTL toDateTime(TimeUnix) + toIntervalDay(${toString ttl.metricsDays})
    PARTITION BY toDate(TimeUnix)
    ORDER BY (ServiceName, MetricName, Attributes, toUnixTimestamp64Nano(TimeUnix))
    SETTINGS index_granularity=8192, ttl_only_drop_parts = 1;

    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_summary_dist ${onCluster}
    AS ${ch.database}.otel_metrics_summary
    ENGINE = Distributed(${cluster}, ${ch.database}, otel_metrics_summary, cityHash64(ServiceName, MetricName));

    -- ─── Metrics: histogram ───────────────────────────────────────
    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_histogram ${onCluster} (
        ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ResourceSchemaUrl String CODEC(ZSTD(1)),
        ScopeName String CODEC(ZSTD(1)),
        ScopeVersion String CODEC(ZSTD(1)),
        ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ScopeDroppedAttrCount UInt32 CODEC(ZSTD(1)),
        ScopeSchemaUrl String CODEC(ZSTD(1)),
        ServiceName LowCardinality(String) CODEC(ZSTD(1)),
        MetricName String CODEC(ZSTD(1)),
        MetricDescription String CODEC(ZSTD(1)),
        MetricUnit String CODEC(ZSTD(1)),
        Attributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        StartTimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        TimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        Count UInt64 CODEC(Delta, ZSTD(1)),
        Sum Float64 CODEC(ZSTD(1)),
        BucketCounts Array(UInt64) CODEC(ZSTD(1)),
        ExplicitBounds Array(Float64) CODEC(ZSTD(1)),
        Exemplars Nested (
            FilteredAttributes Map(LowCardinality(String), String),
            TimeUnix DateTime64(9),
            Value Float64,
            SpanId String,
            TraceId String
        ) CODEC(ZSTD(1)),
        Flags UInt32 CODEC(ZSTD(1)),
        Min Float64 CODEC(ZSTD(1)),
        Max Float64 CODEC(ZSTD(1)),
        AggregationTemporality Int32 CODEC(ZSTD(1)),
        INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1
    ) ENGINE = ${rmt "otel_metrics_histogram"}
    TTL toDateTime(TimeUnix) + toIntervalDay(${toString ttl.metricsDays})
    PARTITION BY toDate(TimeUnix)
    ORDER BY (ServiceName, MetricName, Attributes, toUnixTimestamp64Nano(TimeUnix))
    SETTINGS index_granularity=8192, ttl_only_drop_parts = 1;

    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_histogram_dist ${onCluster}
    AS ${ch.database}.otel_metrics_histogram
    ENGINE = Distributed(${cluster}, ${ch.database}, otel_metrics_histogram, cityHash64(ServiceName, MetricName));

    -- ─── Metrics: exponential histogram ───────────────────────────
    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_exponential_histogram ${onCluster} (
        ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ResourceSchemaUrl String CODEC(ZSTD(1)),
        ScopeName String CODEC(ZSTD(1)),
        ScopeVersion String CODEC(ZSTD(1)),
        ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ScopeDroppedAttrCount UInt32 CODEC(ZSTD(1)),
        ScopeSchemaUrl String CODEC(ZSTD(1)),
        ServiceName LowCardinality(String) CODEC(ZSTD(1)),
        MetricName String CODEC(ZSTD(1)),
        MetricDescription String CODEC(ZSTD(1)),
        MetricUnit String CODEC(ZSTD(1)),
        Attributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        StartTimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        TimeUnix DateTime64(9) CODEC(Delta, ZSTD(1)),
        Count UInt64 CODEC(Delta, ZSTD(1)),
        Sum Float64 CODEC(ZSTD(1)),
        Scale Int32 CODEC(ZSTD(1)),
        ZeroCount UInt64 CODEC(ZSTD(1)),
        PositiveOffset Int32 CODEC(ZSTD(1)),
        PositiveBucketCounts Array(UInt64) CODEC(ZSTD(1)),
        NegativeOffset Int32 CODEC(ZSTD(1)),
        NegativeBucketCounts Array(UInt64) CODEC(ZSTD(1)),
        Exemplars Nested (
            FilteredAttributes Map(LowCardinality(String), String),
            TimeUnix DateTime64(9),
            Value Float64,
            SpanId String,
            TraceId String
        ) CODEC(ZSTD(1)),
        Flags UInt32 CODEC(ZSTD(1)),
        Min Float64 CODEC(ZSTD(1)),
        Max Float64 CODEC(ZSTD(1)),
        AggregationTemporality Int32 CODEC(ZSTD(1)),
        INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1
    ) ENGINE = ${rmt "otel_metrics_exponential_histogram"}
    TTL toDateTime(TimeUnix) + toIntervalDay(${toString ttl.metricsDays})
    PARTITION BY toDate(TimeUnix)
    ORDER BY (ServiceName, MetricName, Attributes, toUnixTimestamp64Nano(TimeUnix))
    SETTINGS index_granularity=8192, ttl_only_drop_parts = 1;

    CREATE TABLE IF NOT EXISTS ${ch.database}.otel_metrics_exponential_histogram_dist ${onCluster}
    AS ${ch.database}.otel_metrics_exponential_histogram
    ENGINE = Distributed(${cluster}, ${ch.database}, otel_metrics_exponential_histogram, cityHash64(ServiceName, MetricName));

    -- ─── Hubble flows ─────────────────────────────────────────────
    -- Our own schema (not from upstream). PR 3's hubble-otel DS will
    -- write here. Keep wide-but-sparse; LowCardinality on identity
    -- fields so disk compresses well even at per-flow granularity.
    CREATE TABLE IF NOT EXISTS ${ch.database}.hubble_flows ${onCluster} (
        Timestamp DateTime64(9) CODEC(Delta(8), ZSTD(1)),
        NodeName LowCardinality(String) CODEC(ZSTD(1)),
        Verdict LowCardinality(String) CODEC(ZSTD(1)),
        DropReason LowCardinality(String) CODEC(ZSTD(1)),
        TrafficDirection LowCardinality(String) CODEC(ZSTD(1)),
        SourceNamespace LowCardinality(String) CODEC(ZSTD(1)),
        SourcePod LowCardinality(String) CODEC(ZSTD(1)),
        SourceWorkload LowCardinality(String) CODEC(ZSTD(1)),
        SourceIdentity UInt32 CODEC(ZSTD(1)),
        SourceIP String CODEC(ZSTD(1)),
        DestinationNamespace LowCardinality(String) CODEC(ZSTD(1)),
        DestinationPod LowCardinality(String) CODEC(ZSTD(1)),
        DestinationWorkload LowCardinality(String) CODEC(ZSTD(1)),
        DestinationIdentity UInt32 CODEC(ZSTD(1)),
        DestinationIP String CODEC(ZSTD(1)),
        L4Protocol LowCardinality(String) CODEC(ZSTD(1)),
        SourcePort UInt16 CODEC(ZSTD(1)),
        DestinationPort UInt16 CODEC(ZSTD(1)),
        L7Type LowCardinality(String) CODEC(ZSTD(1)),
        Attributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        RawFlow String CODEC(ZSTD(1)),
        INDEX idx_verdict Verdict TYPE set(16) GRANULARITY 1,
        INDEX idx_src_pod SourcePod TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_dst_pod DestinationPod TYPE bloom_filter(0.01) GRANULARITY 1
    ) ENGINE = ${rmt "hubble_flows"}
    PARTITION BY toDate(Timestamp)
    ORDER BY (SourceNamespace, Timestamp)
    TTL toDate(Timestamp) + toIntervalDay(${toString ttl.flowsDays})
    SETTINGS index_granularity=8192, ttl_only_drop_parts = 1;

    CREATE TABLE IF NOT EXISTS ${ch.database}.hubble_flows_dist ${onCluster}
    AS ${ch.database}.hubble_flows
    ENGINE = Distributed(${cluster}, ${ch.database}, hubble_flows, cityHash64(SourceNamespace, SourcePod));
  '';

  # ─── OTel Collector helm values ────────────────────────────────────
  # Chart presets pull in kubelet/hostmetrics/logs receivers + RBAC +
  # the boilerplate hostPath mounts. We override `config` entirely so
  # the pipelines, UDS+loopback receivers, and clickhouse exporter
  # land exactly as the design doc specifies. Only the 4 CH nodes are
  # valid placement (nodeAffinity), so each collector pod is next to
  # a CH replica — writes go via 127.0.0.1:9000.
  collectorImageTag = "0.118.0";  # must match clickhouseExporterVersion (sans "v")
  collectorValues = ''
    mode: daemonset

    # Contrib distribution is required for clickhouseexporter and the
    # richer set of receivers we rely on.
    image:
      repository: otel/opentelemetry-collector-contrib
      tag: "${collectorImageTag}"

    command:
      name: otelcol-contrib

    # Presets cover the bulky boilerplate: filelog hostPath mounts,
    # kubeletstats auth, hostmetrics host-proc/sys mounts, and the
    # k8sattributes RBAC + processor. We still override `config` below
    # so the final pipeline is explicit.
    presets:
      logsCollection:
        enabled: true
        includeCollectorLogs: false
      hostMetrics:
        enabled: true
      kubeletMetrics:
        enabled: true
      kubernetesAttributes:
        enabled: true
      kubernetesEvents:
        enabled: true

    # Pin to the 4 CH nodes so every collector pod sits next to a CH
    # replica on the same host (writes go via 127.0.0.1:9000).
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
              - k8s-cp0
              - k8s-cp1
              - k8s-cp2
              - k8s-w3

    # Tolerate control-plane taints so the DS lands on cp0/cp1/cp2.
    tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule

    # CH credentials come from the `otel-ch-credentials` Secret
    # (placeholder in PR 2; populated by the bootstrap-secrets script
    # in PR 4). The collector's clickhouse exporter reads
    # CLICKHOUSE_USER / CLICKHOUSE_PASSWORD via ''${env:VAR}.
    extraEnvsFrom:
    - secretRef:
        name: otel-ch-credentials

    # UDS hostPath shared with hubble-otel (PR 3) and any trace-
    # producing workload on the same node. DirectoryOrCreate lets the
    # collector own the directory even on a fresh node.
    extraVolumes:
    - name: otel-uds
      hostPath:
        path: ${o.udsHostPath}
        type: DirectoryOrCreate

    extraVolumeMounts:
    - name: otel-uds
      mountPath: ${o.udsHostPath}

    resources:
      limits:
        cpu: 1000m
        memory: 1Gi
      requests:
        cpu: 100m
        memory: 256Mi

    # Port map — fully overriding the chart defaults. We disable
    # jaeger-* and zipkin (unused, and `zipkin` collides with `promrw`
    # on 9411); keep OTLP gRPC/HTTP for the loopback/in-cluster path;
    # expose the collector's own /metrics and the prom remote_write
    # receiver used by the cp0-only Prometheus hop.
    ports:
      otlp:
        enabled: true
        containerPort: ${toString o.collector.otlpGrpcPort}
        servicePort: ${toString o.collector.otlpGrpcPort}
        protocol: TCP
      otlp-http:
        enabled: true
        containerPort: 4318
        servicePort: 4318
        protocol: TCP
      metrics:
        enabled: true
        containerPort: ${toString o.collector.metricsPort}
        servicePort: ${toString o.collector.metricsPort}
        protocol: TCP
      promrw:
        enabled: true
        containerPort: ${toString o.collector.promRwPort}
        servicePort: ${toString o.collector.promRwPort}
        protocol: TCP
      jaeger-compact:
        enabled: false
      jaeger-thrift:
        enabled: false
      jaeger-grpc:
        enabled: false
      zipkin:
        enabled: false

    # Full config — replaces (not merges with) the chart's preset
    # defaults for the `receivers`/`processors`/`exporters`/`service`
    # keys. Presets still contribute their RBAC + hostPath volumes.
    config:
      receivers:
        # OTLP: primary ingest via UDS (zero-NIC from co-located
        # workloads) with a loopback TCP fallback for the rare client
        # that can't do UDS.
        otlp:
          protocols:
            grpc:
              endpoint: unix://${o.udsHostPath}/collector.sock
            http:
              endpoint: 0.0.0.0:4318

        # Second OTLP gRPC listener exposed on the Service ClusterIP
        # so in-cluster clients that can't do UDS (hubble-otel, ad-hoc
        # OTLP sources) can reach it without a sidecar hop. Originally
        # bound to 127.0.0.1 when the only consumer was co-located via
        # UDS — relaxed to 0.0.0.0 in PR 5b so the hubble-otel DS can
        # push flows via `otel-collector.observability.svc:4317`.
        otlp/cluster:
          protocols:
            grpc:
              endpoint: 0.0.0.0:${toString o.collector.otlpGrpcPort}

        # Prometheus remote_write receiver — used by the cp0-only Prom
        # remoteWrite hop (PR 3). Bound on 0.0.0.0 because the hop
        # enters via the NodePort Service → pod IP.
        prometheusremotewrite:
          endpoint: 0.0.0.0:${toString o.collector.promRwPort}

      processors:
        memory_limiter:
          check_interval: 1s
          limit_percentage: 75
          spike_limit_percentage: 25

        batch:
          timeout: 5s
          send_batch_size: 8192
          send_batch_max_size: 16384

        # k8sattributes is wired by the preset; extending here to pull
        # pod-level labels onto every signal. Matches the design doc's
        # "resource enrichment" step.
        k8sattributes:
          passthrough: false
          auth_type: serviceAccount
          pod_association:
          - sources:
            - from: resource_attribute
              name: k8s.pod.ip
          - sources:
            - from: connection
          extract:
            metadata:
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.namespace.name
            - k8s.node.name
            - k8s.deployment.name
            labels:
            - tag_name: app
              key: app.kubernetes.io/name
              from: pod

      exporters:
        clickhouse:
          # Loopback-TCP write: CH native protocol on 127.0.0.1:9000.
          # The collector runs on the same node as a CH replica by
          # nodeAffinity, so this never crosses the NIC.
          endpoint: tcp://127.0.0.1:9000?dial_timeout=10s&compress=lz4
          database: ${ch.database}
          username: "''${env:CLICKHOUSE_USER}"
          password: "''${env:CLICKHOUSE_PASSWORD}"
          # The schema-bootstrap Job owns DDL; exporter must not race
          # with it (and we target *_dist tables, which the exporter's
          # CreateSchema path doesn't know about).
          create_schema: false
          logs_table_name: otel_logs_dist
          traces_table_name: otel_traces_dist
          metrics_tables:
            gauge:
              name: otel_metrics_gauge_dist
            sum:
              name: otel_metrics_sum_dist
            summary:
              name: otel_metrics_summary_dist
            histogram:
              name: otel_metrics_histogram_dist
            exponential_histogram:
              name: otel_metrics_exponential_histogram_dist
          ttl: 0s
          timeout: 10s
          sending_queue:
            enabled: true
            queue_size: 5000
          retry_on_failure:
            enabled: true
            initial_interval: 5s
            max_interval: 30s
            max_elapsed_time: 300s

      service:
        telemetry:
          metrics:
            address: 0.0.0.0:${toString o.collector.metricsPort}
        pipelines:
          logs:
            receivers: [otlp, otlp/cluster, filelog, k8s_events]
            processors: [memory_limiter, k8sattributes, batch]
            exporters: [clickhouse]
          traces:
            receivers: [otlp, otlp/cluster]
            processors: [memory_limiter, k8sattributes, batch]
            exporters: [clickhouse]
          metrics:
            receivers: [otlp, otlp/cluster, hostmetrics, kubeletstats, prometheusremotewrite]
            processors: [memory_limiter, k8sattributes, batch]
            exporters: [clickhouse]
  '';

  collectorRendered = helm.renderChart {
    name        = "otel-collector";
    releaseName = "otel-collector";
    namespace   = o.namespace;
    chart       = o.helmCharts.opentelemetryCollector;
    values      = collectorValues;
  };

  # ─── ClickStack (HyperDX UI + MongoDB) helm values ─────────────────
  # The clickstack chart is all-in-one, so we disable the subcharts
  # we already own: ClickHouse (ch4) and the OTel Collector (PR 2 DS).
  # MongoDB stays in-chart with `persistence.enabled=false` (emptyDir
  # — Phase-1 only; session/saved-search state is ephemeral). The
  # hand-written Cilium Ingress + Certificate below replace the chart's
  # nginx-annotated Ingress template.
  clickstackValues = ''
    global:
      storageClassName: "local-path"

    hyperdx:
      replicas: 1
      # frontendUrl is what HyperDX bakes into OAuth redirects + UI
      # links. Must match the Ingress host.
      appUrl: "https://${o.clickstack.host}"
      frontendUrl: "https://${o.clickstack.host}"
      # Pull connections.json + sources.json from a Secret we populate
      # out-of-band via the bootstrap script. This points HyperDX at
      # the ch4 CH cluster + the `otel.*` tables.
      useExistingConfigSecret: true
      existingConfigSecret: "clickstack-hyperdx-config"
      existingConfigConnectionsKey: "connections.json"
      existingConfigSourcesKey: "sources.json"
      # Chart ingress is nginx-annotated and would collide with the
      # Cilium Ingress we emit below. Disable and own the Ingress.
      ingress:
        enabled: false

    mongodb:
      enabled: true
      persistence:
        enabled: false

    # Our ch4 cluster + PR 2 collector DS already own these.
    clickhouse:
      enabled: false
    otel:
      enabled: false

    # No periodic alert-check CronJobs in Phase-1.
    tasks:
      enabled: false
  '';

  clickstackRendered = helm.renderChart {
    name        = "clickstack";
    releaseName = "clickstack";
    namespace   = o.namespace;
    chart       = o.helmCharts.clickstack;
    values      = clickstackValues;
  };
in
{
  manifests = [
    # ─── Schema-bootstrap ConfigMap (DDL payload) ────────────────────
    # sync-wave 0: has to exist before the Job (wave 1) references it.
    {
      name = "observability/configmap-schema-ddl.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: otel-schema-ddl
          namespace: ${o.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "0"
          labels:
            app.kubernetes.io/name: otel-schema-bootstrap
            app.kubernetes.io/part-of: observability
            observability.nix-k8s-examples/exporter-version: "${o.clickhouseExporterVersion}"
        data:
          bootstrap.sql: |
            ${lib.replaceStrings [ "\n" ] [ "\n            " ] (lib.removeSuffix "\n" bootstrapSql)}
        # NOTE: DDL content indented 12 spaces by the replaceStrings above —
        # 8 stripped as common indent, yielding 4 spaces of block-scalar
        # indent in the final YAML (i.e. nested under `bootstrap.sql: |`).
      '';
    }

    # ─── CH credentials Secret (placeholder) ─────────────────────────
    # PR 4 overwrites this with real `otel` / `hyperdx` creds via the
    # bootstrap-secrets script. Until then the collector talks to CH
    # as the built-in `default` user (password-less in the lab), so
    # the DS is actually functional from day one.
    {
      name = "observability/secret-ch-credentials.yaml";
      content = ''
        apiVersion: v1
        kind: Secret
        metadata:
          name: otel-ch-credentials
          namespace: ${o.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "0"
            # Phase-1 placeholder: the bootstrap-secrets script in PR 4
            # replaces this Secret with generated creds. Ignored so
            # re-runs of `argocd sync` don't wipe the real values.
            argocd.argoproj.io/compare-options: IgnoreExtraneous
          labels:
            app.kubernetes.io/name: otel-ch-credentials
            app.kubernetes.io/part-of: observability
        type: Opaque
        stringData:
          CLICKHOUSE_USER: "default"
          CLICKHOUSE_PASSWORD: ""
      '';
    }

    # ─── Schema-bootstrap Job ────────────────────────────────────────
    # sync-wave 1: runs after the ConfigMap (wave 0) and before the
    # collector DS (wave 2). Idempotent — all DDL uses IF NOT EXISTS.
    # Talks to the cluster-wide ClickHouse Service so any replica can
    # drive the `ON CLUSTER ch4` DDL fan-out.
    {
      name = "observability/job-schema-bootstrap.yaml";
      content = ''
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: otel-schema-bootstrap
          namespace: ${o.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "1"
            argocd.argoproj.io/hook: Sync
            # Replace on each sync so DDL changes (new exporter version
            # bump) get re-applied. Idempotent by construction.
            argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
          labels:
            app.kubernetes.io/name: otel-schema-bootstrap
            app.kubernetes.io/part-of: observability
        spec:
          backoffLimit: 10
          template:
            metadata:
              labels:
                app.kubernetes.io/name: otel-schema-bootstrap
            spec:
              restartPolicy: OnFailure
              containers:
              - name: clickhouse-client
                image: clickhouse/clickhouse-server:24.3
                command:
                  - /bin/sh
                  - -c
                  - |
                    set -e
                    # Wait until the cluster-wide Service has endpoints.
                    until clickhouse-client \
                        --host clickhouse.clickhouse.svc.cluster.local \
                        --query "SELECT 1" >/dev/null 2>&1; do
                      echo "waiting for ClickHouse..."
                      sleep 2
                    done
                    echo "applying schema (${o.clickhouseExporterVersion})..."
                    clickhouse-client \
                        --host clickhouse.clickhouse.svc.cluster.local \
                        --multiquery \
                        --multiline \
                        --queries-file /ddl/bootstrap.sql
                    echo "schema applied."
                volumeMounts:
                - name: ddl
                  mountPath: /ddl
                resources:
                  requests:
                    cpu: 50m
                    memory: 128Mi
                  limits:
                    cpu: 500m
                    memory: 512Mi
              volumes:
              - name: ddl
                configMap:
                  name: otel-schema-ddl
      '';
    }

    # ─── OTel Collector DS (helm-rendered) ───────────────────────────
    # sync-wave 2: waits for the schema Job (wave 1) to complete.
    # The rendered manifest stream includes RBAC, ConfigMap, DS, SA
    # from the upstream chart; nodeAffinity + UDS + CH exporter come
    # from collectorValues.
    {
      name = "observability/collector-install.yaml";
      source = "${collectorRendered}/install.yaml";
    }
    # Audit copy of the values used at render time (mirrors cilium.nix).
    {
      name = "observability/collector-values.yaml";
      content = collectorValues;
    }

    # ─── cp0 NodePort for Prometheus → collector remote_write ────────
    # The Prom → remote_write hop is loopback TCP on cp0 (see
    # nix/monitoring-module.nix wired in PR 3). NixOS Prom talks to
    # `127.0.0.1:${nodePort}` → NodePort → one of the collector pods.
    # Since every collector pod has a promrw receiver, any Service
    # endpoint is fine.
    {
      name = "observability/service-collector-promrw.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: otel-collector-promrw
          namespace: ${o.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "2"
          labels:
            app.kubernetes.io/name: otel-collector-promrw
            app.kubernetes.io/part-of: observability
        spec:
          type: NodePort
          selector:
            app.kubernetes.io/name: opentelemetry-collector
            app.kubernetes.io/instance: otel-collector
          ports:
          - name: promrw
            port: ${toString o.collector.promRwPort}
            targetPort: ${toString o.collector.promRwPort}
            nodePort: ${toString o.collector.nodePort}
            protocol: TCP
      '';
    }

    # ─── ClickStack UI (HyperDX + MongoDB) ───────────────────────────
    # sync-wave 4: lands after the collector (wave 2). The UI only
    # reads from CH via the `hyperdx` role, so it tolerates an empty
    # otel.* schema — no hard dependency on the bootstrap Job.
    {
      name   = "observability/clickstack-install.yaml";
      source = "${clickstackRendered}/install.yaml";
    }
    # Audit copy of the values used at render time.
    {
      name    = "observability/clickstack-values.yaml";
      content = clickstackValues;
    }

    # ─── HyperDX connections.json / sources.json Secret (placeholder) ─
    # The bootstrap-secrets script overwrites this with a connections
    # JSON that includes the real `hyperdx` CH password. Until then,
    # HyperDX comes up with an empty connection set and the UI reports
    # "no sources configured" — functional but inert.
    {
      name    = "observability/secret-clickstack-hyperdx-config.yaml";
      content = ''
        apiVersion: v1
        kind: Secret
        metadata:
          name: clickstack-hyperdx-config
          namespace: ${o.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
            argocd.argoproj.io/compare-options: IgnoreExtraneous
          labels:
            app.kubernetes.io/name: clickstack-hyperdx-config
            app.kubernetes.io/part-of: observability
        type: Opaque
        stringData:
          connections.json: "[]"
          sources.json: "[]"
      '';
    }

    # ─── Certificate (sync-wave 2) ───────────────────────────────────
    # Mirrors rendered/nginx/certificate.yaml — self-signed ClusterIssuer
    # from cert-manager, ECDSA P-256, 90-day cert with 30-day renewal.
    {
      name    = "observability/certificate.yaml";
      content = ''
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: clickstack-tls
          namespace: ${o.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "2"
        spec:
          secretName: clickstack-tls
          duration: 2160h
          renewBefore: 720h
          privateKey:
            algorithm: ECDSA
            size: 256
          dnsNames:
          - ${o.clickstack.host}
          issuerRef:
            name: selfsigned-lab
            kind: ClusterIssuer
            group: cert-manager.io
      '';
    }

    # ─── Cilium Ingress (sync-wave 5) ────────────────────────────────
    # Mirrors rendered/nginx/ingress.yaml shape. VIP 10.33.33.50 is
    # advertised by the Cilium LB-IP pool; the host header
    # `clickstack.lab.local` routes to the HyperDX app Service.
    {
      name    = "observability/ingress.yaml";
      content = ''
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: clickstack
          namespace: ${o.namespace}
          annotations:
            cert-manager.io/cluster-issuer: selfsigned-lab
            argocd.argoproj.io/sync-wave: "5"
        spec:
          ingressClassName: ${o.clickstack.ingressClassName}
          tls:
          - hosts:
            - ${o.clickstack.host}
            secretName: clickstack-tls
          rules:
          - host: ${o.clickstack.host}
            http:
              paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: clickstack-app
                    port: { number: 3000 }
      '';
    }

    # ─── hubble-otel DaemonSet (sync-wave 3) ────────────────────────
    # Forwards Hubble L3/L4/L7 flows from the node-local cilium-agent
    # into the OTel Collector DS, which in turn writes them into the
    # `otel.hubble_flows*` CH tables created by the schema-bootstrap
    # Job. Image is built from source by nix/images/hubble-otel.nix
    # (upstream repo is archived, no published container); pushed into
    # the in-cluster Zot registry at registry.lab.local/hubble-otel.
    #
    # Pod runs on hostNetwork so it can reach the local cilium-agent
    # Hubble listener at localhost:4244 without a Service hop.
    # dnsPolicy: ClusterFirstWithHostNet preserves cluster DNS so the
    # OTLP exporter can resolve otel-collector.observability.svc.
    {
      name = "observability/hubble-otel-serviceaccount.yaml";
      content = ''
        apiVersion: v1
        kind: ServiceAccount
        metadata:
          name: hubble-otel
          namespace: ${o.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
      '';
    }
    {
      name    = "observability/hubble-otel-daemonset.yaml";
      content = ''
        apiVersion: apps/v1
        kind: DaemonSet
        metadata:
          name: hubble-otel
          namespace: ${o.namespace}
          labels:
            app.kubernetes.io/name: hubble-otel
            app.kubernetes.io/component: flow-adapter
          annotations:
            argocd.argoproj.io/sync-wave: "3"
        spec:
          selector:
            matchLabels:
              app.kubernetes.io/name: hubble-otel
          template:
            metadata:
              labels:
                app.kubernetes.io/name: hubble-otel
                app.kubernetes.io/component: flow-adapter
            spec:
              serviceAccountName: hubble-otel
              # hostNetwork so `localhost:4244` resolves to the
              # cilium-agent Hubble listener (cilium-agent also runs
              # on hostNetwork). ClusterFirstWithHostNet keeps cluster
              # DNS for the OTLP collector Service lookup.
              hostNetwork: true
              dnsPolicy: ClusterFirstWithHostNet
              # Same placement as the collector DS — every CH node
              # gets a collector + a hubble-otel side-by-side.
              affinity:
                nodeAffinity:
                  requiredDuringSchedulingIgnoredDuringExecution:
                    nodeSelectorTerms:
                    - matchExpressions:
                      - key: kubernetes.io/hostname
                        operator: In
                        values:
                        - k8s-cp0
                        - k8s-cp1
                        - k8s-cp2
                        - k8s-w3
              tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              - key: node-role.kubernetes.io/master
                operator: Exists
                effect: NoSchedule
              containers:
              - name: hubble-otel
                image: ${constants.observability.hubbleOtel.image}
                imagePullPolicy: IfNotPresent
                args:
                - "-hubble.address=${constants.observability.hubbleOtel.hubbleAddress}"
                - "-otlp.address=otel-collector.${o.namespace}.svc.cluster.local:${toString o.collector.otlpGrpcPort}"
                # In-cluster OTLP is plaintext (the collector's
                # otlp/cluster receiver has no TLS); flip this and
                # wire certs once mutual TLS lands cluster-wide.
                - "-otlp.tls.enable=false"
                # Export both logs and traces — the collector's
                # logs + traces pipelines both ingest otlp/cluster.
                - "-logs.export=true"
                - "-trace.export=true"
                - "-fallbackServiceNamePrefix=hubble"
                resources:
                  requests:
                    cpu: 50m
                    memory: 64Mi
                  limits:
                    cpu: 500m
                    memory: 256Mi
                securityContext:
                  runAsNonRoot: true
                  runAsUser: 65532
                  allowPrivilegeEscalation: false
                  readOnlyRootFilesystem: true
                  capabilities:
                    drop: ["ALL"]
      '';
    }

    # ─── ArgoCD Application ──────────────────────────────────────────
    {
      name = "observability/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: observability
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/observability
            directory:
              recurse: false
              exclude: '{application.yaml,collector-values.yaml,clickstack-values.yaml}'
          destination:
            server: https://kubernetes.default.svc
            namespace: ${o.namespace}
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
            syncOptions:
              - ServerSideApply=true
              - CreateNamespace=true
              - RespectIgnoreDifferences=true
          ignoreDifferences:
            # Bootstrap-secrets script overwrites these Secrets'
            # data out-of-band. Prevent ArgoCD from reverting real
            # creds back to the placeholders on every self-heal.
            - group: ""
              kind: Secret
              name: otel-ch-credentials
              namespace: ${o.namespace}
              jsonPointers: ["/data", "/stringData"]
            - group: ""
              kind: Secret
              name: clickstack-hyperdx-config
              namespace: ${o.namespace}
              jsonPointers: ["/data", "/stringData"]
      '';
    }
  ];
}
