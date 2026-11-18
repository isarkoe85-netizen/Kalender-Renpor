FROM ruby:3.3-slim
WORKDIR /app
RUN gem install webrick --no-document
COPY server.rb ./
COPY public ./public
ENV PORT=10000 DB_FILE=/data/data.json
RUN mkdir -p /data
EXPOSE 10000
CMD ["ruby", "server.rb"]
