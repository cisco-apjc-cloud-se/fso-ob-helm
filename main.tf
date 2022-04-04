terraform {
  backend "remote" {
    hostname = "app.terraform.io"
    organization = "mel-ciscolabs-com"
    workspaces {
      name = "fso-ob-helm"
    }
  }
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

### Remote State - Import Kube Config ###
data "terraform_remote_state" "iks" {
  backend = "remote"

  config = {
    organization = "mel-ciscolabs-com"
    workspaces = {
      name = "fso-ob-iks"
    }
  }
}

### Decode Kube Config ###
locals {
  kube_config = yamldecode(base64decode(data.terraform_remote_state.iks.outputs.kube_config))
}


### Providers ###

provider "kubernetes" {
  # alias = "iks-k8s"
  host                   = local.kube_config.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kube_config.clusters[0].cluster.certificate-authority-data)
  client_certificate     = base64decode(local.kube_config.users[0].user.client-certificate-data)
  client_key             = base64decode(local.kube_config.users[0].user.client-key-data)
}

provider "helm" {
  kubernetes {
    host                   = local.kube_config.clusters[0].cluster.server
    cluster_ca_certificate = base64decode(local.kube_config.clusters[0].cluster.certificate-authority-data)
    client_certificate     = base64decode(local.kube_config.users[0].user.client-certificate-data)
    client_key             = base64decode(local.kube_config.users[0].user.client-key-data)
  }
}

### Kubernetes  ###

### Add Namespaces ###

resource "kubernetes_namespace" "sca" {
  metadata {
    annotations = {
      name = "sca"
    }
    labels = {
      # app = "sca"
      "app.kubernetes.io/name" = "sca"
    }
    name = "sca"
  }
}

resource "kubernetes_namespace" "iwo-collector" {
  metadata {
    annotations = {
      name = "iwo-collector"
    }
    labels = {
      # app = "iwo"
      "app.kubernetes.io/name" = "iwo"
    }
    name = "iwo-collector"
  }
}

resource "kubernetes_namespace" "online-boutique" {
  metadata {
    annotations = {
      name = "online-boutique"
    }
    labels = {
      "app.kubernetes.io/name" = "online-boutique"
      "app.kubernetes.io/version" = "0.1.0"

      ## SMM Sidecard Proxy Auto Injection ##
      "istio.io/rev" = "cp-v111x.istio-system"

      ## SecureCN
      "SecureApplication-protected" = "full"

    }
    name = "online-boutique"
  }
}

resource "kubernetes_namespace" "appd" {
  metadata {
    annotations = {
      name = "appdynamics"
    }
    labels = {
      # app = "appdynamics"
      "app.kubernetes.io/name" = "appdynamics"
    }
    name = "appdynamics"
  }
}

### Helm ###

## Add Secure Cloud Analytics - K8S Agent Release ##
resource "helm_release" "sca" {
 namespace   = kubernetes_namespace.sca.metadata[0].name
 name        = "sca"

 chart       = var.sca_chart_url

 set {
   name  = "sca.service_key"
   value = var.sca_service_key
 }
}

## Add IWO K8S Collector Release ##
resource "helm_release" "iwo-collector" {
 namespace   = kubernetes_namespace.iwo-collector.metadata[0].name
 name        = "iwo-collector"

 chart       = var.iwo_chart_url

 set {
   ## Get latest DC image
   name   = "connectorImage.tag"
   value  = var.dc_image_version
 }

 # set {
 #   ### Controllablee?
 #   name  = "annotations.kubeturbo.io/controllable"
 #   value = "true"
 # }

 set {
   name  = "iwoServerVersion"
   value = var.iwo_server_version
 }

 set {
   name  = "collectorImage.tag"
   value = var.iwo_collector_image_version
 }

 set {
   name  = "targetName"
   value = var.iwo_cluster_name
 }

#  values = [<<EOF
#    annotations:
#      kubeturbo.io/controllable: "true"
# EOF
# ]

}

## Add Online Boutique Release  ##

resource "helm_release" "online-boutique" {
 namespace   = kubernetes_namespace.online-boutique.metadata[0].name
 name        = "online-boutique"

 chart       = var.demo_app_url

 values = [ <<EOF
 adservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/adservice # gcr.io/google-samples/microservices-demo/adservice
       tag: latest # v0.1.0
     requests:
       cpu: 400m
       memory: 360Mi
     limits:
       cpu: 600m
       memory: 600Mi
     env:
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=adservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 9555 ## External Port for LoadBalancer/NodePort
       targetPort: 9555

 cartservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/cartservice # gcr.io/google-samples/microservices-demo/cartservice
       tag: latest # v0.1.0
     requests:
       cpu: 200m
       memory: 64Mi
     limits:
       cpu: 300m
       memory: 128Mi
     env:
       REDIS_ADDR: "redis-cart:6379"
       OTEL_EXPORTER_OTLP_ENDPOINT: "http://otelcollector:4317" # NOT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT !?
       OTEL_RESOURCE_ATTRIBUTES: "service.name=cartservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 7070 ## External Port for LoadBalancer/NodePort
       targetPort: 7070

 checkoutservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/checkoutservice # gcr.io/google-samples/microservices-demo/checkoutservice
       tag: latest # v0.1.0
     requests:
       cpu: 100m
       memory: 64Mi
     limits:
       cpu: 200m
       memory: 128Mi
     env:
       PRODUCT_CATALOG_SERVICE_ADDR: "productcatalogservice:3550"
       SHIPPING_SERVICE_ADDR: "shippingservice:50051"
       PAYMENT_SERVICE_ADDR: "paymentservice:50051"
       EMAIL_SERVICE_ADDR: "emailservice:5000"
       CURRENCY_SERVICE_ADDR: "currencyservice:7000"
       CART_SERVICE_ADDR: "cartservice:7070"
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=checkoutservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 5050 ## External Port for LoadBalancer/NodePort
       targetPort: 5050

 currencyservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/currencyservice # gcr.io/google-samples/microservices-demo/currencyservice
       tag: latest # v0.1.0
     requests:
       cpu: 100m
       memory: 64Mi
     limits:
       cpu: 200m
       memory: 128Mi
     env:
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=currencyservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 7000 ## External Port for LoadBalancer/NodePort
       targetPort: 7000


 emailservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/emailservice # gcr.io/google-samples/microservices-demo/emailservice
       tag: latest # v0.1.0
     requests:
       cpu: 100m
       memory: 64Mi
     limits:
       cpu: 200m
       memory: 128Mi
     env:
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=emailservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 5000 ## External Port for LoadBalancer/NodePort
       targetPort: 8080

 frontend:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/frontend # gcr.io/google-samples/microservices-demo/frontend
       tag: latest # v0.1.0
     requests:
       cpu: 100m
       memory: 64Mi
     limits:
       cpu: 200m
       memory: 128Mi
     env:
       PRODUCT_CATALOG_SERVICE_ADDR: "productcatalogservice:3550"
       CURRENCY_SERVICE_ADDR: "currencyservice:7000"
       CART_SERVICE_ADDR: "cartservice:7070"
       RECOMMENDATION_SERVICE_ADDR: "recommendationservice:8080"
       SHIPPING_SERVICE_ADDR: "shippingservice:50051"
       CHECKOUT_SERVICE_ADDR: "checkoutservice:5050"
       AD_SERVICE_ADDR: "adservice:9555"
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=frontend,service.version=1.0.0"
       # ENV_PLATFORM: One of: local, gcp, aws, azure, onprem, alibaba
       # When not set, defaults to "local" unless running in GKE, otherwies auto-sets to gcp
       ENV_PLATFORM: "local"
       CYMBAL_BRANDING: "'false'" # disabled
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     http:
       port: 80 ## External Port for LoadBalancer/NodePort
       targetPort: 8080

 frontendexternal:
   service:
     type: NodePort # ClusterIP, NodePort, LoadBalancer
     http:
       port: 80 ## External Port for LoadBalancer/NodePort
       targetPort: 8080

 jaeger:
   replicas: 1
   server:
     image:
       name: jaegertracing/all-in-one
       tag: latest # 1.31
     requests:
       cpu: 200m
       memory: 180Mi
     limits:
       cpu: 300m
       memory: 300Mi
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     p5775:
       port: 5775
       targetPort: 5775
       protocol: UDP
     p6831:
       port: 6831
       targetPort: 6831
       protocol: UDP
     p6832:
       port: 6832
       targetPort: 6832
       protocol: UDP
     p5778:
       port: 5778
       targetPort: 5778
     p14250:
       port: 14250
       targetPort: 14250
     p14268:
       port: 14268
       targetPort: 14268
     p14269:
       port: 14269
       targetPort: 14269
     p9411:
       port: 9411
       targetPort: 9411

 jaegerfrontend:
   service:
     type: NodePort # ClusterIP, NodePort, LoadBalancer
     p16686:
       port: 16686
       targetPort: 16686

 loadgenerator:
   replicas: 1
   frontendcheck:
     image:
       name: busybox
       tag: latest
     env:
       FRONTEND_ADDR: "frontend:80"
   main:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/loadgenerator # gcr.io/google-samples/microservices-demo/loadgenerator
       tag: latest # v0.1.0
     requests:
       cpu: 300m
       memory: 256Mi
     limits:
       cpu: 500m
       memory: 512Mi
     env:
       FRONTEND_ADDR: "frontend:80"
       USERS: "'10'"

 otelcollector:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/otelcollector
       tag: latest # v0.1.0
     requests:
       cpu: 200m
       memory: 180Mi
     limits:
       cpu: 300m
       memory: 300Mi
     env:
       APPD_ENDPOINT: "https://pdx-sls-agent-api.saas.appdynamics.com/"
       APPD_KEY: "${var.appd_account_key}"
       APPD_CONTROLLER_ACCOUNT: "${var.appd_account_name}"
       APPD_CONTROLLER_HOST: "${var.appd_account_name}.saas.appdynamics.com"
       APPD_CONTROLLER_PORT: "'443'"
       SERVICE_NAMESPACE: "online-boutique"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     p1888:
       port: 1888
       targetPort: 1888
     p8888:
       port: 8888
       targetPort: 8888
     p8889:
       port: 8889
       targetPort: 8889
     p13133:
       port: 13133
       targetPort: 13133
     p4317:
       port: 4317
       targetPort: 4317
     p55670:
       port: 55670
       targetPort: 55670

 paymentservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/paymentservice # gcr.io/google-samples/microservices-demo/paymentservice
       tag: latest # v0.1.0
     requests:
       cpu: 100m
       memory: 64Mi
     limits:
       cpu: 200m
       memory: 128Mi
     env:
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=paymentservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 50051 ## External Port for LoadBalancer/NodePort
       targetPort: 50051

 paymentservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/paymentservice # gcr.io/google-samples/microservices-demo/paymentservice
       tag: latest # v0.1.0
     requests:
       cpu: 100m
       memory: 64Mi
     limits:
       cpu: 200m
       memory: 128Mi
     env:
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=paymentservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 50051 ## External Port for LoadBalancer/NodePort
       targetPort: 50051

 productcatalogservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/productcatalogservice # gcr.io/google-samples/microservices-demo/productcatalogservice
       tag: latest # v0.1.0
     requests:
       cpu: 100m
       memory: 64Mi
     limits:
       cpu: 200m
       memory: 128Mi
     env:
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=productcatalogservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 3550 ## External Port for LoadBalancer/NodePort
       targetPort: 3550

 recommendationservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/recommendationservice # gcr.io/google-samples/microservices-demo/recommendationservice
       tag: latest # v0.1.0
     requests:
       cpu: 100m
       memory: 220Mi
     limits:
       cpu: 200m
       memory: 450Mi
     env:
       PRODUCT_CATALOG_SERVICE_ADDR: "productcatalogservice:3550"
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=recommendationservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 8080 ## External Port for LoadBalancer/NodePort
       targetPort: 8080

 redis:
   replicas: 1
   server:
     image:
       name: redis
       tag: alpine
     requests:
       cpu: 70m
       memory: 200Mi
     limits:
       cpu: 125m
       memory: 256Mi
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     redis:
       port: 6379 ## External Port for LoadBalancer/NodePort
       targetPort: 6379

 shippingservice:
   replicas: 1
   server:
     image:
       name: public.ecr.aws/j8r8c0y6/otel-online-boutique/shippingservice # gcr.io/google-samples/microservices-demo/shippingservice
       tag: latest # v0.1.0
     requests:
       cpu: 100m
       memory: 220Mi
     limits:
       cpu: 200m
       memory: 450Mi
     env:
       PRODUCT_CATALOG_SERVICE_ADDR: "productcatalogservice:3550"
       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://otelcollector:4317"
       OTEL_RESOURCE_ATTRIBUTES: "service.name=shippingservice,service.version=1.0.0"
   service:
     type: ClusterIP # ClusterIP, NodePort, LoadBalancer
     grpc:
       port: 50051 ## External Port for LoadBalancer/NodePort
       targetPort: 50051

EOF
 ]

}

# ## Add Tea Store Release  ##
# resource "helm_release" "fso-teastore" {
#  namespace   = kubernetes_namespace.teastore.metadata[0].name
#  name        = "fso-teastore"
#
#  chart       = var.teastore_chart_url
#
#  values = [<<EOF
# OrderProcessor: false
# Log4ShellDemo: false
#
# teastore_auth:
#  replicas: 1
#  resources:
#    memory: "256M"
#    cpu: "500m"
#  service:
#    type: ClusterIP # ClusterIP, NodePort, LoadBalancer
#    targetPort: 8080
#    port: 8080 ## External Port for LoadBalancer/NodePort
#
# teastore_db:
#  replicas: 1
#  resources:
#    memory: "256M"
#    cpu: "200m" # "500m" scaled down by IWO
#  service:
#    type: ClusterIP # ClusterIP, NodePort, LoadBalancer
#    targetPort: 3306
#    port: 3306 ## External Port for LoadBalancer/NodePort
#
# teastore_image:
#  replicas: 1
#  resources:
#    memory: "256M"
#    cpu: "500m"
#  service:
#    type: ClusterIP # ClusterIP, NodePort, LoadBalancer
#    targetPort: 8080
#    port: 8080 ## External Port for LoadBalancer/NodePort
#
# teastore_loadgen:
#  replicas: 0 # Off by default
#  resources:
#    memory: "256M"
#    cpu: "200m" # "500m" scaled down by IWO
#  settings:
#    num_users: 10
#    ramp_up: 1
#
# teastore_loadgen_amex:
#  replicas: 0 # Off by default
#  resources:
#    memory: "256M"
#    cpu: "200m" # "500m" scaled down by IWO
#  settings:
#    num_users: 10
#    ramp_up: 1
#
# teastore_persistence:
#  replicas: 1
#  resources:
#    memory: "256M"
#    cpu: "500m"
#  service:
#    type: ClusterIP # ClusterIP, NodePort, LoadBalancer
#    targetPort: 8080
#    port: 8080 ## External Port for LoadBalancer/NodePort
#
# ### Used for Memory Leak Detection in AppD ###
# teastore_ldap:
#  replicas: 0
#  resources:
#    memory: "256M"
#    cpu: "500m"
#  service:
#    type: ClusterIP # ClusterIP, NodePort, LoadBalancer
#    revshell:
#      port: 8888
#      targetPort: 8888 ## External Port for LoadBalancer/NodePort
#    ldap:
#      port: 1389
#      targetPort: 1389 ## External Port for LoadBalancer/NodePort
#
# ### Used for Memory Leak Detection in AppD ###
# teastore_orderprocessor:
#  replicas: 0
#  resources:
#    memory: "256M"
#    cpu: "500m"
#  settings:
#    mem_increment_mb: 1
#    processing_rate_seconds: 15
#    max_jvm_heap: "512m"
#
# teastore_recommender:
#  replicas: 1
#  resources:
#    memory: "256M"
#    cpu: "400m" # "500m" scaled down by IWO
#  service:
#    type: ClusterIP # ClusterIP, NodePort, LoadBalancer
#    targetPort: 8080
#    port: 8080 ## External Port for LoadBalancer/NodePort
#
# teastore_registry:
#  replicas: 1
#  resources:
#    memory: "256M"
#    cpu: "100m"  ## "500m" lowered by IWO
#  service:
#    type: ClusterIP # ClusterIP, NodePort, LoadBalancer
#    targetPort: 8080
#    port: 8080 ## External Port for LoadBalancer/NodePort
#
# teastore_webui:
#  v1:
#    replicas: 1
#  v2:
#    replicas: 1
#  v3:
#    replicas: 0
#  resources:
#    memory: "256M"
#    cpu: "500m"
#  service:
#    type: LoadBalancer # ClusterIP, NodePort, LoadBalancer
#    targetPort: 8080
#    port: 8080 ## External Port for LoadBalancer/NodePort
#  env:
#    visa_url: "https://fso-payment-gw-sim.azurewebsites.net/api/payment"
#    mastercard_url: "https://fso-payment-gw-sim.azurewebsites.net/api/payment"
#    amex_url: "https://amex-fso-payment-gw-sim.azurewebsites.net/api/payment"
# EOF
# ]
#
#  depends_on = [helm_release.appd-cluster-agent]
# }

## Add Metrics Server Release ##
# - Required for AppD Cluster Agent

resource "helm_release" "metrics-server" {
  name = "metrics-server"
  namespace = "kube-system"
  repository = "https://charts.bitnami.com/bitnami"
  chart = "metrics-server"

  set {
    name = "apiService.create"
    value = true
  }

  set {
    name = "extraArgs.kubelet-insecure-tls"
    value = true
  }

  set {
    name = "extraArgs.kubelet-preferred-address-types"
    value = "InternalIP"
  }

}

## Add Appd Cluster Agent Release  ##
resource "helm_release" "appd-cluster-agent" {
 namespace   = kubernetes_namespace.appd.metadata[0].name
 name        = "fso-ob-cluster-agent"

 repository  = "https://ciscodevnet.github.io/appdynamics-charts"
 chart       = "cluster-agent"

 ### Set Image Tag Version to Latest ###
 set {
   name = "imageInfo.agentTag"
   value = "latest"
 }

 set {
   name = "imageInfo.machineAgentTag"
   value = "latest"
 }

 set {
   name = "imageInfo.netvizTag"
   value = "latest"
 }

 set {
   name = "imageInfo.operatorTag"
   value = "latest"
 }

 ### Agent Pod CPU/RAM Requests/Limits ###
 set {
   name = "agentPod.resources.limits.cpu"
   value = "1250m"
 }

 set {
   name = "agentPod.resources.limits.memory"
   value = "428Mi" # "300Mi" raised by IWO
 }

 set {
   name = "agentPod.resources.requests.cpu"
   value = "350m" # "750m" lowered by IWO
 }

 set {
   name = "agentPod.resources.requests.memory"
   value = "150Mi"
 }

 ### Enable InfraViz ###
 set {
   name = "installInfraViz"
   value = true
 }

 ### Enable NetViz ###
 set {
   name = "netViz.enabled"
   value = false
 }

 ### Enable Docker Visibility ###
 set {
   name = "infraViz.enableDockerViz"
   value = true
 }

 ### Enable Server Visibility ###
 set {
   name = "infraViz.enableServerViz"
   value = true
 }

 # infraViz:
 #   enableContainerHostId: false
 #   enableDockerViz: false
 #   enableMasters: false
 #   enableServerViz: false
 #   nodeOS: linux
 #   stdoutLogging: false

 ### Machine / Infra Viz Agent Pod Sizes ###
 set {
   name = "infravizPod.resources.limits.cpu"
   value = "500m"
 }

 set {
   name = "infravizPod.resources.limits.memory"
   value = "1G"
 }

 set {
   name = "infravizPod.resources.requests.cpu"
   value = "200m"
 }

 set {
   name = "infravizPod.resources.requests.memory"
   value = "800m"
 }

 ### Controller Details ###

 set {
   name = "controllerInfo.url"
   value = format("https://%s.saas.appdynamics.com:443", var.appd_account_name)
 }

 set {
   name = "controllerInfo.account"
   value = var.appd_account_name
 }

 set {
   name = "controllerInfo.accessKey"
   value = var.appd_account_key
 }

 set {
   name = "controllerInfo.username"
   value = var.appd_account_username
 }

 set {
   name = "controllerInfo.password"
   value = var.appd_account_password
 }

 ## Monitor All Namespaces
 set {
   name = "clusterAgent.nsToMonitorRegex"
   value = ".*"
 }

#  ## Auto Instrumentation
#
# # auto-instrumentation config
#  values = [<<EOF
#  instrumentationConfig:
#    enabled: true
#    instrumentationMethod: env
#    nsToInstrumentRegex: teastore
#    defaultAppName: TeaStore-RW
#    appNameStrategy: manual
#    instrumentationRules:
#      - namespaceRegex: teastore
#        language: java
#        labelMatch:
#          - framework: java
#        imageInfo:
#          image: docker.io/appdynamics/java-agent:latest
#          agentMountPath: /opt/appdynamics
#          imagePullPolicy: Always
# EOF
# ]

 depends_on = [helm_release.metrics-server]
}

# ## Add Prometheus (Kube-state-metrics, node-exporter, alertmanager)  ##
# resource "helm_release" "prometheus" {
#   namespace   = "kube-system"
#   name        = "prometheus"
#
#   repository  = "https://prometheus-community.github.io/helm-charts"
#   chart       = "prometheus"
#
#   ## Delay Chart Deployment
#   depends_on = [helm_release.metrics-server]
# }
