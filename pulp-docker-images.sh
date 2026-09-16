PULP=3.70   # check quay.io/repository/pulp/pulp-minimal?tab=tags first

docker pull quay.io/pulp/pulp-minimal:$PULP
docker pull quay.io/pulp/pulp-web:$PULP
docker pull registry.access.redhat.com/ubi9/postgresql-16:latest
docker pull registry.access.redhat.com/ubi9/nginx-124:latest
docker pull docker.io/library/redis:7-alpine
docker pull registry.access.redhat.com/ubi9/python-311:latest
docker pull registry.access.redhat.com/ubi9/nodejs-20:latest
