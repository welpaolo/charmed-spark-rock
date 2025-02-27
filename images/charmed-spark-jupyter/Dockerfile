# ---------------------------------------------------------------------------
# This is an OCI image to deploy JupyterLab server instances on K8s, fully
# integrated with Charmed Spark ecosystem and utilities. The image provides an
# automated and seamless user-experience to deploy, operate, manage and monitor
# SparkJob running on K8s cluster.
# It is an open source, end-to-end, production ready data platform on top of
# cloud native technologies.
# ---------------------------------------------------------------------------

ARG BASE_IMAGE=base-charmed-spark:latest
ARG JUPYTERLAB_VERSION=4.0.0
FROM $BASE_IMAGE

ARG JUPYTERLAB_VERSION
USER root

RUN rm /var/lib/pebble/default/layers/*.yaml /opt/pebble/*.sh

RUN python3 -m pip install "jupyterlab==$JUPYTERLAB_VERSION"
COPY ./pebble/layers.yaml /var/lib/pebble/default/layers/001-charmed-jupyter.yaml
COPY ./bin/jupyterlab-server.sh /opt/pebble/jupyterlab-server.sh
RUN chown _daemon_:_daemon_ /opt/pebble/jupyterlab-server.sh

USER _daemon_

# Provide Default Entrypoint for Pebble
ENTRYPOINT [ "/bin/pebble", "enter", "--verbose", "--args", "jupyter" ]