Instructions
============

### Build the updated container
```
podman build -t openclaw .
```

### Run the new container with host networking
```
podman run -d --network=host --name openclaw-test localhost/openclaw:latest
```

### Check the logs
```
podman logs -f openclaw-test
```

### Access
```
http://127.0.0.1:3000/chat?session=main&token=openclaw-token-123
```

