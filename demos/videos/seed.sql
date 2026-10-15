-- Domain tables for the recorded demos. Runs once at Postgres initdb time.
-- The tenant rows live in tenant.sql, which runs after Restdis has created
-- its control-plane tables on first boot.

CREATE TABLE products (
  id integer PRIMARY KEY,
  name text NOT NULL,
  price integer NOT NULL
);

ALTER TABLE products REPLICA IDENTITY FULL;

INSERT INTO products (id, name, price) VALUES
  (1, 'Espresso', 300),
  (2, 'Flat white', 450),
  (3, 'Cold brew', 500);

CREATE TABLE todos (
  id integer PRIMARY KEY,
  title text NOT NULL,
  done boolean NOT NULL DEFAULT false
);

ALTER TABLE todos REPLICA IDENTITY FULL;

INSERT INTO todos (id, title, done) VALUES
  (1, 'Point the app at Restdis', true),
  (2, 'Delete the hand-written cache code', false);
