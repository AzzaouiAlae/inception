# Stage 1: Build
FROM alpine:3.23 AS build

RUN apk update && apk add --no-cache dotnet10-sdk

WORKDIR /src
COPY ./App /src

RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish

# Stage 2: Runtime
FROM alpine:3.23

RUN apk update && apk add --no-cache aspnetcore10-runtime

WORKDIR /app
COPY --from=build /app/publish .

ENV ASPNETCORE_URLS=http://+:5000
EXPOSE 5000

CMD ["dotnet", "cv.dll"]
