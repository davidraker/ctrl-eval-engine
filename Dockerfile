FROM public.ecr.aws/docker/library/julia:1.11.6
COPY .aws/config /root/.aws/config

WORKDIR /app
COPY app/Project.toml /app/
RUN julia --project=. -e "using Pkg; Pkg.instantiate();"

COPY app /app
RUN julia --project=. -e "using Pkg; Pkg.precompile();"
