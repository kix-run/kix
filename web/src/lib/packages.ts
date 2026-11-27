export type PackageLevel = 'stable' | 'experimental';

export type CategoryId =
  | 'data'
  | 'networking'
  | 'observability'
  | 'security'
  | 'storage'
  | 'cluster'
  | 'apps'
  | 'other';

export interface CatalogPackage {
  name: string;
  level: PackageLevel;
  summary: string;
  fullDescription: string;
  docsHref: string;
  order: number;
}

export interface PackageFamily {
  id: string;
  category: CategoryId;
  title: string;
  mode?: string;
  note?: string;
  packages: CatalogPackage[];
}

export interface CatalogGroup {
  id: CategoryId;
  title: string;
  families: PackageFamily[];
}

interface FamilySpec {
  id: string;
  category: CategoryId;
  title: string;
  mode?: string;
  note?: string;
  members: [name: string, summary: string][];
}

const CATEGORIES: { id: CategoryId; title: string }[] = [
  { id: 'data', title: 'Databases, caches, and messaging' },
  { id: 'observability', title: 'Observability' },
  { id: 'networking', title: 'Networking, DNS, and certificates' },
  { id: 'security', title: 'Secrets, identity, and security' },
  { id: 'storage', title: 'Storage and backups' },
  { id: 'cluster', title: 'Cluster and compute' },
  { id: 'apps', title: 'Applications' },
  { id: 'other', title: 'Other' },
];

// Ecosystem groupings and concise descriptions for the marketing page.
// Actual package existence, stability, and docs URLs are derived at build time
// from kix/packages/{stable,experimental}/*/default.nix.
const FAMILY_SPECS: FamilySpec[] = [
  // Databases, caches, and messaging
  {
    id: 'cnpg',
    category: 'data',
    title: 'PostgreSQL · CloudNativePG',
    mode: 'operator-managed',
    members: [
      ['cnpg-operator', 'CloudNativePG operator controller'],
      ['cnpg-cluster', 'PostgreSQL cluster (via operator)'],
      ['cnpg-database', 'Logical database and login role'],
      ['cnpg-pooler', 'PgBouncer connection pooler'],
      ['cnpg-barman-cloud', 'WAL archiving and object-store backups'],
    ],
  },
  {
    id: 'stackgres',
    category: 'data',
    title: 'PostgreSQL · StackGres',
    mode: 'operator-managed',
    members: [
      ['stackgres-operator', 'StackGres operator controller'],
      ['stackgres-cluster', 'PostgreSQL cluster (via operator)'],
      ['stackgres-database', 'Logical database and login role'],
      ['stackgres-object-storage', 'Object-storage backup target'],
    ],
  },
  {
    id: 'clickhouse',
    category: 'data',
    title: 'ClickHouse',
    mode: 'standalone or operator',
    note: 'Run <code>clickhouse</code> for a single node with no operator, or <code>clickhouse-cluster</code> with the Altinity operator and Keeper. <code>clickhouse-database</code> works with either.',
    members: [
      ['clickhouse', 'Single node with embedded Keeper (no operator)'],
      ['clickhouse-operator', 'Altinity ClickHouse operator'],
      ['clickhouse-keeper', 'Keeper quorum (for operator clusters)'],
      ['clickhouse-cluster', 'Replicated cluster (via operator)'],
      ['clickhouse-database', 'Database, user, and credentials'],
      ['clickhouse-logs', 'Vector pod log shipper into ClickHouse'],
    ],
  },
  {
    id: 'db-operator',
    category: 'data',
    title: 'External Databases · DB Operator',
    mode: 'operator-managed',
    note: 'Provision databases, users, and Secrets on an existing PostgreSQL or MySQL server such as RDS.',
    members: [
      ['db-operator', 'Controller and admission webhook'],
      ['db-operator-instance', 'External database server target'],
      ['db-operator-database', 'Database, user, and credentials Secret'],
    ],
  },
  {
    id: 'rabbitmq',
    category: 'data',
    title: 'RabbitMQ',
    mode: 'operator-managed',
    members: [
      ['rabbitmq-operator', 'RabbitMQ Cluster Operator'],
      ['rabbitmq-cluster', 'RabbitMQ cluster (via operator)'],
    ],
  },
  {
    id: 'valkey-nats',
    category: 'data',
    title: 'Valkey & NATS',
    mode: 'no operator',
    members: [
      ['valkey', 'Redis-compatible primary or Sentinel-replicated store'],
      ['nats', 'Standalone or clustered NATS with JetStream'],
    ],
  },

  // Observability
  {
    id: 'victoria-metrics',
    category: 'observability',
    title: 'VictoriaMetrics',
    mode: 'operator-managed',
    members: [
      ['victoria-metrics-operator', 'VictoriaMetrics Operator'],
      ['victoria-metrics-cluster', 'Clustered storage, select, and insert (via operator)'],
      ['victoria-metrics-agent', 'Metric scraper (VMAgent)'],
      ['victoria-metrics-alert', 'Alerting rules and Alertmanager (VMAlert)'],
    ],
  },
  {
    id: 'prometheus',
    category: 'observability',
    title: 'Prometheus',
    mode: 'operator-managed',
    members: [
      ['prometheus-operator', 'Prometheus Operator and monitor CRDs'],
      ['prometheus', 'Prometheus server (via operator)'],
      ['alertmanager', 'Alertmanager (via operator)'],
      ['prometheus-default-rules', 'Default Kubernetes alert rules'],
    ],
  },
  {
    id: 'grafana-loki-tempo',
    category: 'observability',
    title: 'Grafana, Loki & Tempo',
    mode: 'no operator',
    members: [
      ['grafana', 'Dashboards and visualization'],
      ['loki', 'Single-binary Loki log store'],
      ['loki-logs', 'Vector pod log shipper into Loki'],
      ['tempo', 'Single-binary Tempo trace store'],
    ],
  },
  {
    id: 'otel-exporters',
    category: 'observability',
    title: 'OpenTelemetry & Exporters',
    mode: 'no operator',
    members: [
      ['otel-collector', 'OpenTelemetry Collector (gateway or DaemonSet)'],
      ['kube-state-metrics', 'Kubernetes object state metrics'],
      ['node-exporter', 'Host hardware and OS metrics'],
      ['metrics-server', 'Resource metrics API (kubectl top, HPA)'],
      ['dns-exporter', 'Prometheus DNS query probe exporter'],
      ['smartctl-exporter', 'SMART disk health metrics'],
    ],
  },

  // Networking, DNS, and certificates
  {
    id: 'envoy-gateway',
    category: 'networking',
    title: 'Envoy Gateway',
    mode: 'operator-managed',
    members: [
      ['gateway-api', 'Standard-channel Gateway API CRDs'],
      ['envoy-gateway-controller', 'Envoy Gateway controller'],
      ['envoy-gateway', 'Envoy Gateway proxy (via controller)'],
    ],
  },
  {
    id: 'traefik-caddy',
    category: 'networking',
    title: 'Traefik & Caddy',
    mode: 'no operator',
    members: [
      ['traefik', 'Traefik Gateway API controller and proxy'],
      ['caddy', 'Caddy web server and reverse proxy'],
    ],
  },
  {
    id: 'cert-manager',
    category: 'networking',
    title: 'cert-manager',
    mode: 'operator-managed',
    members: [
      ['cert-manager', 'X.509 certificate controller and webhook'],
      ['cluster-issuer', 'Cluster-wide TLS issuer (ClusterIssuer)'],
    ],
  },
  {
    id: 'cni-dns-tunnels',
    category: 'networking',
    title: 'CNI, DNS & Tunnels',
    members: [
      ['cilium', 'CNI and CiliumNetworkPolicy enforcement'],
      ['coredns', 'Cluster DNS server (no operator)'],
      ['external-dns', 'External DNS record sync'],
      ['cloudflared', 'Cloudflare Tunnel connector (no operator)'],
      ['tailscale', 'Tailscale operator, subnet routers, and proxies'],
    ],
  },

  // Secrets, identity, and security
  {
    id: 'external-secrets',
    category: 'security',
    title: 'External Secrets & Infisical',
    mode: 'operator-managed',
    members: [
      ['external-secrets', 'External Secrets Operator'],
      ['external-secret', 'Synced ExternalSecret (via operator)'],
      ['infisical-operator', 'Infisical secret sync operator'],
    ],
  },
  {
    id: 'native-secrets-openbao',
    category: 'security',
    title: 'Secrets & OpenBao',
    mode: 'no operator',
    members: [
      ['secret', 'Kix-managed Secret (SOPS or inline)'],
      ['secret-ref', 'Reference to an externally managed Secret'],
      ['openbao', 'OpenBao secrets manager on Raft'],
    ],
  },
  {
    id: 'identity',
    category: 'security',
    title: 'Keycloak & OIDC',
    mode: 'no operator',
    members: [
      ['keycloak', 'Keycloak identity and access management'],
      ['oidc-client', 'OpenID Connect application client'],
    ],
  },
  {
    id: 'runtime-security',
    category: 'security',
    title: 'Runtime Security',
    mode: 'no operator',
    members: [['falco', 'Falco eBPF system-call security agent']],
  },

  // Storage and backups
  {
    id: 'volumes-csi',
    category: 'storage',
    title: 'Volumes, Snapshots & CSI Drivers',
    members: [
      ['storage-classes', 'StorageClasses for cluster CSI drivers'],
      ['persistent-volume-claim', 'Standalone PersistentVolumeClaim'],
      ['snapshot-controller', 'CSI VolumeSnapshot controller and CRDs'],
      ['mayastor', 'OpenEBS Mayastor replicated NVMe-oF storage'],
      ['zfs-localpv', 'OpenEBS local ZFS volume driver'],
    ],
  },
  {
    id: 'backups',
    category: 'storage',
    title: 'Backups & Replication',
    members: [
      ['velero', 'Cluster and volume backup and restore'],
      ['volsync', 'Asynchronous PVC replication (operator)'],
    ],
  },

  // Cluster and compute
  {
    id: 'github-runners',
    category: 'cluster',
    title: 'GitHub Actions Runners',
    mode: 'operator-managed',
    members: [
      ['arc', 'Actions Runner Controller'],
      ['arc-runner-set', 'Autoscaling runner scale set (via arc)'],
    ],
  },
  {
    id: 'kubevirt',
    category: 'cluster',
    title: 'Virtual Machines · KubeVirt',
    mode: 'operator-managed',
    members: [
      ['kubevirt', 'KubeVirt operator and VM runtime'],
      ['cdi', 'Containerized Data Importer for VM disk images'],
    ],
  },
  {
    id: 'scaling-lifecycle',
    category: 'cluster',
    title: 'Scaling, Scheduling & Images',
    members: [
      ['keda', 'Event-driven autoscaler (operator)'],
      ['descheduler', 'Pod placement evictor'],
      ['reloader', 'Restarts pods when referenced Secrets change'],
      ['spegel', 'Node-to-node OCI image mirror'],
    ],
  },
  {
    id: 'primitives',
    category: 'cluster',
    title: 'Cluster Primitives',
    mode: 'no operator',
    members: [
      ['priority-class', 'Workload PriorityClass'],
      ['service-ref', 'Reference to an unmanaged Service'],
      ['echo-server', 'HTTP echo server for connectivity checks'],
    ],
  },

  // Applications
  {
    id: 'immich',
    category: 'apps',
    title: 'Immich',
    mode: 'no operator',
    members: [
      ['immich', 'Photo and video library server and web UI'],
      ['immich-machine-learning', 'Face recognition, OCR, and smart search worker'],
    ],
  },
  {
    id: 'self-hosted-apps',
    category: 'apps',
    title: 'Self-Hosted Apps & Registries',
    mode: 'no operator',
    members: [
      ['harbor', 'Harbor OCI container registry'],
      ['n8n', 'n8n workflow automation with queue workers'],
      ['metabase', 'Metabase business intelligence and analytics'],
      ['plausible', 'Plausible web analytics'],
      ['vaultwarden', 'Vaultwarden password manager'],
      ['filebrowser', 'Web-based file manager'],
    ],
  },
];

const NIX_PACKAGES = import.meta.glob<string>(
  '../../../kix/packages/{stable,experimental}/*/default.nix',
  { query: '?raw', import: 'default', eager: true }
);

function parseMeta(source: string, filePath: string): { description: string; deprecated: boolean } {
  const blockMatch = source.match(/\bmeta\s*=\s*\{([\s\S]*?)\n  \};/);
  const block = blockMatch?.[1] ?? '';
  const descMatch =
    block.match(/description\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/) ??
    source.match(/\bmeta\.description\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/);
  if (!descMatch?.[1]) {
    throw new Error(`Missing meta.description in ${filePath}`);
  }
  const description = descMatch[1].replace(/\\"/g, '"');
  const deprecated = /\bdeprecated\s*=/.test(block);
  return { description, deprecated };
}

function fallbackSummary(description: string): string {
  const firstSentence = description.split(/\.\s+/)[0] ?? description;
  return firstSentence.replace(/\.$/, '');
}

export function loadPackageCatalog(): { groups: CatalogGroup[]; total: number } {
  const discovered = new Map<string, { level: PackageLevel; description: string; docsHref: string }>();

  const parsedEntries = Object.entries(NIX_PACKAGES).map(([filePath, source]) => {
    const match = filePath.match(/\/kix\/packages\/(stable|experimental)\/([^/]+)\/default\.nix$/);
    if (!match) throw new Error(`Unexpected package path: ${filePath}`);
    return {
      level: match[1] as PackageLevel,
      name: match[2]!,
      filePath,
      source,
    };
  });

  // Sort experimental before stable so a graduated stable package of the same name wins.
  parsedEntries.sort((a, b) => {
    if (a.level === b.level) return a.name.localeCompare(b.name);
    return a.level === 'experimental' ? -1 : 1;
  });

  for (const entry of parsedEntries) {
    const { description, deprecated } = parseMeta(entry.source, entry.filePath);
    if (deprecated) continue;
    const docsPath = entry.level === 'stable' ? entry.name : `experimental/${entry.name}`;
    discovered.set(entry.name, {
      level: entry.level,
      description,
      docsHref: `/docs/main/reference/package-catalog/${docsPath}/`,
    });
  }

  if (discovered.size === 0) {
    throw new Error('No packages discovered in kix/packages/{stable,experimental}');
  }

  const assigned = new Set<string>();
  const families: PackageFamily[] = [];

  for (const spec of FAMILY_SPECS) {
    const packages: CatalogPackage[] = [];
    spec.members.forEach(([name, summary], idx) => {
      const found = discovered.get(name);
      if (!found) return;
      assigned.add(name);
      packages.push({
        name,
        level: found.level,
        summary,
        fullDescription: found.description,
        docsHref: found.docsHref,
        order: idx,
      });
    });
    if (packages.length > 0) {
      families.push({
        id: spec.id,
        category: spec.category,
        title: spec.title,
        mode: spec.mode,
        note: spec.note,
        packages,
      });
    }
  }

  // Any newly added package not yet listed in FAMILY_SPECS still appears automatically.
  const unassigned = Array.from(discovered.entries())
    .filter(([name]) => !assigned.has(name))
    .sort(([a], [b]) => a.localeCompare(b));

  if (unassigned.length > 0) {
    families.push({
      id: 'other',
      category: 'other',
      title: 'Additional packages',
      packages: unassigned.map(([name, found], idx) => ({
        name,
        level: found.level,
        summary: fallbackSummary(found.description),
        fullDescription: found.description,
        docsHref: found.docsHref,
        order: idx,
      })),
    });
  }

  const groups: CatalogGroup[] = CATEGORIES.map((cat) => ({
    id: cat.id,
    title: cat.title,
    families: families.filter((f) => f.category === cat.id),
  })).filter((g) => g.families.length > 0);

  return { groups, total: discovered.size };
}
