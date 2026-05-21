# YourOwn.Chat server config


```sh
kubectl config use-context ${CLUSTER_NAME}

helm repo add mattermost https://helm.mattermost.com --force-update

kubectl apply -n mattermost -f certs.yaml

helm upgrade -i mattermost \
  -n mattermost \
  --create-namespace \
  -f operator.yaml \
  mattermost/mattermost-operator \
  --wait

kubectl apply -n mattermost -f mattermost.yaml
kubectl apply -n mattermost -f ingress.yaml

helm upgrade -i yourown-chat-rtcd \
  -n mattermost \
  --create-namespace \
  -f rtcd.yaml \
  mattermost/yourown-chat-rtcd \
  --wait

kubectl apply -n mattermost -f lb.yaml
```