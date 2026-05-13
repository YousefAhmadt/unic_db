FROM dart:stable

WORKDIR /app

COPY pubspec.* ./
RUN dart pub get

COPY . .

RUN dart compile exe server.dart -o server

EXPOSE 8080

CMD ["./server"]