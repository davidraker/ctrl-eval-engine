FROM public.ecr.aws/docker/library/julia:1
COPY .aws/config /root/.aws/config

WORKDIR /app
COPY app/Project.toml /app/
RUN julia --project=. -e "using Pkg; Pkg.update();"

COPY app /app
RUN julia --project=. -e "using Pkg; Pkg.precompile();"
