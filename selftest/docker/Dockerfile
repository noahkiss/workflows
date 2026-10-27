FROM alpine:3.22
ARG REV=none
RUN echo "built on $(uname -m) rev ${REV}" > /built
CMD ["cat", "/built"]
