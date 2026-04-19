# nix/gitops/matrix/element.nix
#
# Element Web — the official Matrix web client.
#
# Stateless, single nginx-based image that serves static assets. Config
# lives in /app/config.json, which the image reads at request time; we
# mount it from a ConfigMap so changes can be edited in git.
#
{ constants }:
let
  m   = constants.matrix;
  mns = "matrix";
in
{
  manifests = [
    {
      name = "matrix/element-configmap.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: element-config
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "4"
        data:
          config.json: |
            {
              "default_server_config": {
                "m.homeserver": {
                  "base_url": "https://${m.serverName}",
                  "server_name": "${m.serverName}"
                }
              },
              "brand": "Element (lab)",
              "disable_custom_urls": false,
              "disable_guests": true,
              "disable_login_language_selector": false,
              "disable_3pid_login": true,
              "default_theme": "dark",
              "show_labs_settings": true,
              "features": {},
              "room_directory": {
                "servers": ["${m.serverName}"]
              }
            }
      '';
    }

    {
      name = "matrix/element-deployment.yaml";
      content = ''
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: element
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "5"
        spec:
          replicas: 2
          selector:
            matchLabels: { app: element }
          template:
            metadata:
              labels: { app: element }
            spec:
              tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              containers:
              - name: element
                image: ${m.images.element}
                ports:
                - { name: http, containerPort: 80 }
                readinessProbe:
                  httpGet: { path: /, port: 80 }
                  initialDelaySeconds: 3
                  periodSeconds: 5
                resources:
                  requests: { cpu: 20m,  memory: 32Mi }
                  limits:   { cpu: 200m, memory: 128Mi }
                volumeMounts:
                - name: config
                  mountPath: /app/config.json
                  subPath: config.json
                  readOnly: true
              volumes:
              - name: config
                configMap:
                  name: element-config
                  items: [{ key: config.json, path: config.json }]
      '';
    }

    {
      name = "matrix/element-service.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: element
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "5"
        spec:
          type: ClusterIP
          selector: { app: element }
          ports:
          - { name: http, port: 80, targetPort: 80 }
      '';
    }
  ];
}
