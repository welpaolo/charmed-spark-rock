microk8s status --wait-ready
microk8s config | tee ~/.kube/config
microk8s.enable dns
microk8s.enable rbac
microk8s.enable minio
microk8s.enable gpu