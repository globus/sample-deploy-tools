# Dockerfile that describes how to build an application container

# Python base image (in turn based off Debian)
FROM python:3.6.9

# install application supporting libraries, build tools and configuration

RUN pip3 install poetry==1.0.0b3

RUN apt-get update && apt-get install -y python3-virtualenv uwsgi uwsgi-src \
        uwsgi-plugin-python3 openssl make gcc musl-dev libffi-dev \
        postgresql-server-dev-11 python3-psycopg2

# build uwsgi plugin for python3.6
RUN wget https://projects.unbit.it/downloads/uwsgi-2.0.18.tar.gz 2>&1 \
        && tar -xvzf uwsgi-2.0.18.tar.gz \
        && mv uwsgi-2.0.18 uwsgi \
        && cd uwsgi \
        && make PROFILE=nolang \
        && PYTHON=python3.6 \
        && ./uwsgi --build-plugin "plugins/python python36" \
        && mv python36_plugin.so plugins/python \
        && cd .. \
        && mv uwsgi /usr/local \
        && ln -s /usr/local/uwsgi/uwsgi /usr/local/bin/uwsgi

# copy configuration files into the Docker image

COPY deployment/uwsgi.yaml /etc/uwsgi/uwsgi.yaml

COPY . /subscription

WORKDIR /subscription

# final application build commands
RUN make deploy

# specify the command to run when the container starts
CMD ["scripts/run_docker.sh"]

# application server will listen for inbound connections on TCP port 8443
EXPOSE 8443
