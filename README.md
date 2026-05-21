# YourOwn.Chat Server open config


```sh
kubectl config use-context ${CLUSTER_NAME}

helm repo add mattermost https://helm.mattermost.com --force-update

kubectl apply -n mattermost -f certs.yaml || { echo "!!! Failed to apply cert.yaml"; exit 1; }

helm upgrade -i mattermost \
  -n mattermost \
  --create-namespace \
  -f operator.yaml \
  mattermost/mattermost-operator \
  --wait || { echo "!!! Failed to upgrade/install"; exit 1; }

kubectl apply -n mattermost -f mattermost.yaml || { echo "!!! Failed to apply mattermost.yaml"; exit 1; }
kubectl apply -n mattermost -f ingress.yaml || { echo "!!! Failed to apply ingress.yaml"; exit 1; }

helm upgrade -i yourown-chat-rtcd \
  -n mattermost \
  --create-namespace \
  -f rtcd.yaml \
  mattermost/yourown-chat-rtcd \
  --wait || { echo "!!! Failed to upgrade/install"; exit 1; }

kubectl apply -n mattermost -f lb.yaml || { echo "!!! Failed to apply lb.yaml"; exit 1; }
```