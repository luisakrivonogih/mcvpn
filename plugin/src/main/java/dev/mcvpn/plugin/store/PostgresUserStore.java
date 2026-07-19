package dev.mcvpn.plugin.store;

import java.util.concurrent.ExecutorService;

import com.zaxxer.hikari.HikariConfig;

/** Postgres-backed {@link UserStore}: {@code BYTEA} binary columns, {@code VARCHAR(36)} ids. */
public final class PostgresUserStore extends AbstractJdbcUserStore {

    public PostgresUserStore(String host, int port, String database, String user, String password,
            ExecutorService dbExecutor) {
        super(buildConfig(host, port, database, user, password), dbExecutor);
    }

    private static HikariConfig buildConfig(String host, int port, String database, String user, String password) {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl("jdbc:postgresql://" + host + ":" + port + "/" + database);
        config.setUsername(user);
        config.setPassword(password);
        config.setPoolName("mcvpn-postgres");
        return config;
    }

    @Override
    protected String binaryColumnType(int lengthBytes) {
        return "BYTEA";
    }

    @Override
    protected String idColumnType() {
        return "VARCHAR(36)";
    }
}
