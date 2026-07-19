package dev.mcvpn.plugin.store;

import java.util.concurrent.ExecutorService;

import com.zaxxer.hikari.HikariConfig;

/** MariaDB-backed {@link UserStore}: {@code VARBINARY} binary columns, {@code CHAR(36)} ids. */
public final class MariaUserStore extends AbstractJdbcUserStore {

    public MariaUserStore(String host, int port, String database, String user, String password,
            ExecutorService dbExecutor) {
        super(buildConfig(host, port, database, user, password), dbExecutor);
    }

    private static HikariConfig buildConfig(String host, int port, String database, String user, String password) {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl("jdbc:mariadb://" + host + ":" + port + "/" + database);
        config.setUsername(user);
        config.setPassword(password);
        config.setPoolName("mcvpn-mariadb");
        return config;
    }

    @Override
    protected String binaryColumnType(int lengthBytes) {
        return "VARBINARY(" + lengthBytes + ")";
    }

    @Override
    protected String idColumnType() {
        return "CHAR(36)";
    }
}
