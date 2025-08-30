# CSE160 Docker Workflow

## Start container
# (Run these in Windows Command Prompt with Docker Desktop running)
docker start CSE160_p0
docker exec -it CSE160_p0 /bin/bash

## Inside container
cd /home/cse160
make micaz sim
python2 pingTest.py   # or TestSim.py depending on assignment

## When done
exit
docker stop CSE160_p0

### Reminders:
⚠️ DO NOT run "docker run" again for this project — only "docker start" + "docker exec".
⚠️ DO NOT edit files inside the container — always code in VS Code on Windows under skel/.